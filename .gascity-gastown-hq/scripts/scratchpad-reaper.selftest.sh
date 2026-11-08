#!/bin/bash
# scratchpad-reaper.selftest.sh — unit tests for the PURE decision logic of
# scratchpad-reaper.sh: liveness lookup, mtime staleness, and the composed
# reap gate (dead AND stale AND not-self).
#
# Hermetic: sources the script as a LIBRARY (SCRATCHPAD_REAPER_LIB=1) so
# main() never runs, points the log at a throwaway path. Never calls
# `gc session list`, never `rm -rf`s anything, never touches real
# /private/tmp/claude-* data — all fixtures are synthetic temp files/values.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/scratchpad-reaper.sh"

export SCRATCHPAD_REAPER_LIB=1
export SCRATCHPAD_REAPER_LOG="/tmp/scratchpad-reaper-selftest-$$.log"
# shellcheck disable=SC1090
. "$SCRIPT"

# Captured immediately after the ONLY source of this file, before any test
# below overrides SCRATCH_REAL_DEFAULT_ROOT for hermetic fixture scenarios —
# this is the pristine production value (ga-h565g production-constant check
# near the end of this file). Deliberately NOT re-sourced later: main()'s
# `trap ... RETURN` (harmless in production, where every real invocation is a
# fresh subprocess) leaks past a single function return in bash and fires
# again on the next sourced-script completion in the SAME shell, by which
# point the original invocation's local $keyfile is out of scope — re-sourcing
# after this file's main() scenarios run would hit that landmine under `set -u`.
PRODUCTION_REAL_DEFAULT_ROOT="$SCRATCH_REAL_DEFAULT_ROOT"

# ga-hynohs: main() also takes a single-instance lock, cross-checks liveness
# against running `claude` processes, and deletes through safe-clean. Every
# main() scenario below has to stay hermetic, so:
#   - LOCK_DIR is a throwaway path — never the production lock (a real sweep
#     holding it would make main() skip and fail these tests at random);
#   - the process scan is a no-op (real `ps` would inject the live town's ids);
#   - removal is an rm -rf stand-in — safe-clean refuses fixture roots under
#     /tmp BY DESIGN, so a stub is the only way to test main()'s decisions.
# The two real functions are saved here and get their own sections further
# down. On a script that predates ga-hynohs the saves are empty and the stubs
# are never called, so this block is a no-op there.
LOCK_PARENT="$(mktemp -d /tmp/scratchpad-reaper-selftest-lock.XXXXXX)"
LOCK_DIR="$LOCK_PARENT/lock.d"
REAL_PROC_FN="$(declare -f _fetch_proc_liveness)"
REAL_REMOVE_FN="$(declare -f _remove_scratchpad)"
REAL_LIVE_FN="$(declare -f _fetch_live_keys)"   # ga-7jtyqjy: the main() scenarios stub it; its own section below needs the real one
_fetch_proc_liveness() { return 0; }
_remove_scratchpad() { rm -rf "$1"; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== scratchpad-reaper.selftest.sh ==="

# ── fixture: a live-keys file with two known session ids ────────────────────
KEYFILE="$(mktemp /tmp/scratchpad-reaper-selftest-keys.XXXXXX)"
printf 'alive-session-1\nalive-session-2\n' > "$KEYFILE"
trap 'rm -f "$KEYFILE"; rm -rf "$LOCK_PARENT"' EXIT

# ── _session_is_live: exact-line membership, not substring/prefix ───────────
_session_is_live "alive-session-1" "$KEYFILE" && ok "session_is_live: exact match in keyfile → true" || bad "should be live"
_session_is_live "dead-session-9" "$KEYFILE"   && bad "session_is_live: absent id should be false" || ok "session_is_live: absent id → false"
_session_is_live "alive-session"  "$KEYFILE"   && bad "session_is_live: PREFIX match must NOT count as live (substring false-positive)" || ok "session_is_live: prefix-only is not a match (-x exact line)"
_session_is_live "alive-session-1" "/nonexistent/keyfile-$$" && bad "session_is_live: missing keyfile should be false (fail toward dead, not live)" || ok "session_is_live: missing keyfile → false"

# ── _is_stale: hour-boundary math, non-numeric fail-closed (never stale) ────
NOW=1000000
_is_stale $(( NOW - 25*3600 )) "$NOW" 24 && ok "is_stale: 25h old, min 24h → stale" || bad "25h should be stale at min=24h"
_is_stale $(( NOW - 24*3600 )) "$NOW" 24 && ok "is_stale: exactly 24h old → stale (boundary inclusive)" || bad "24h boundary should be inclusive"
_is_stale $(( NOW - 23*3600 )) "$NOW" 24 && bad "is_stale: 23h old should NOT be stale yet" || ok "is_stale: 23h old → not stale"
_is_stale ""    "$NOW" 24 && bad "is_stale: empty mtime (stat failed) must NOT be stale (never authorize deletion on unreadable mtime)" || ok "is_stale: empty mtime → false (fail toward keep)"
_is_stale "abc" "$NOW" 24 && bad "is_stale: non-numeric mtime should be false" || ok "is_stale: non-numeric mtime → false"

# ── _should_reap: composed gate — self-protection beats everything, then
#    liveness, then staleness ────────────────────────────────────────────────
OLD=$(( NOW - 48*3600 ))
RECENT=$(( NOW - 1*3600 ))
_should_reap "dead-session-9"  "$KEYFILE" "$OLD"    "$NOW" 24 ""               && ok "should_reap: dead + stale + no self set → reap"                            || bad "dead+stale should reap"
_should_reap "alive-session-1" "$KEYFILE" "$OLD"    "$NOW" 24 ""               && bad "should_reap: live session must NEVER reap regardless of age"             || ok "should_reap: live session → never reap"
_should_reap "dead-session-9"  "$KEYFILE" "$RECENT" "$NOW" 24 ""               && bad "should_reap: dead but too recent must NOT reap"                          || ok "should_reap: dead-but-fresh → not yet"
_should_reap "dead-session-9"  "$KEYFILE" "$OLD"    "$NOW" 24 "dead-session-9" && bad "should_reap: CURRENT session id must NEVER reap even if it otherwise qualifies" || ok "should_reap: self-protection overrides dead+stale"
_should_reap "alive-session-1" "$KEYFILE" "$OLD"    "$NOW" 24 "dead-session-9" && bad "should_reap: unrelated self id must not change a live session's outcome" || ok "should_reap: self set but different id → still protected by liveness"

# ── _prod_sentinel_active: PRODUCTION SENTINEL (ga-h565g) — a resolved root
#    equal to the real default with no explicit prod opt-in must block
#    deletion. Pure/no filesystem access: these pass plain strings; the actual
#    production constant is exercised separately below via main() ──────────
_prod_sentinel_active "/private/tmp/claude-501" "/private/tmp/claude-501" ""  && ok "prod_sentinel_active: root==real default, no PROD → active (blocks)"        || bad "root==default+no PROD should be active"
_prod_sentinel_active "/private/tmp/claude-501" "/private/tmp/claude-501" "0" && ok "prod_sentinel_active: root==real default, PROD=0 → active (blocks)"         || bad "root==default+PROD=0 should be active"
_prod_sentinel_active "/private/tmp/claude-501" "/private/tmp/claude-501" "1" && bad "prod_sentinel_active: PROD=1 must disable the sentinel even when root==default" || ok "prod_sentinel_active: root==default+PROD=1 → not active (allowed)"
_prod_sentinel_active "/tmp/some-fixture-root"  "/private/tmp/claude-501" ""  && bad "prod_sentinel_active: a DIFFERENT (fixture) root must never trip the sentinel"  || ok "prod_sentinel_active: fixture root != default → not active"
_prod_sentinel_active "/tmp/some-fixture-root"  "/private/tmp/claude-501" "1" && bad "prod_sentinel_active: fixture root + PROD=1 must still be inactive"        || ok "prod_sentinel_active: fixture root + PROD=1 → not active"

echo ""
echo "=== main(): production sentinel end-to-end (ga-h565g) ==="
# Hermetic trick: reassign SCRATCH_REAL_DEFAULT_ROOT (a plain global, not
# readonly) to a disposable tmp path so these scenarios exercise the REAL
# main() sentinel-forcing logic end-to-end without ever pointing at the
# actual /private/tmp/claude-<uid> — the sentinel compares SCRATCH_ROOT
# against WHATEVER SCRATCH_REAL_DEFAULT_ROOT currently holds, so this is a
# faithful exercise of the same code path production uses, just pointed at a
# throwaway fixture. A separate check further below (outside this override)
# confirms the constant's REAL value is the actual expected production path.
_fetch_live_keys() { : > "$1"; }  # nobody "live" — every candidate is dead
OLD_TS="$(date -v-5d +%Y%m%d%H%M.%S)"
SENTINEL_ROOT="$(mktemp -d /tmp/scratchpad-reaper-selftest-sentinel.XXXXXX)"

make_sentinel_fixture() {
  rm -rf "$SENTINEL_ROOT"
  mkdir -p "$SENTINEL_ROOT/proj/dead-old/scratchpad"
  touch -t "$OLD_TS" "$SENTINEL_ROOT/proj/dead-old/scratchpad"
}

SCRATCH_REAL_DEFAULT_ROOT="$SENTINEL_ROOT"   # pretend this tmp dir IS "the real default"
SCRATCH_ROOT="$SENTINEL_ROOT"                # and the resolved root equals it exactly
# shellcheck disable=SC2034  # read by main() in the sourced script
ENABLED=1
# shellcheck disable=SC2034  # read by main()/_should_reap in the sourced script
MIN_AGE_HOURS=24
# shellcheck disable=SC2034  # read by main()/_should_reap in the sourced script
SELF_SESSION_ID=""

# Scenario: real-default root, no PROD opt-in → must NOT delete.
make_sentinel_fixture
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
# shellcheck disable=SC2034  # read by main() in the sourced script
PROD=0
main
[ -d "$SENTINEL_ROOT/proj/dead-old/scratchpad" ] && ok "main(): root==real-default + no PROD opt-in → candidate survives (sentinel blocks deletion)" || bad "main(): sentinel FAILED to block — real-default root deleted data with no PROD opt-in"

# Scenario: same root, PROD=1 → normal reap resumes (real launchd-path behavior).
make_sentinel_fixture
DRY_RUN=0; PROD=1
main
[ -d "$SENTINEL_ROOT/proj/dead-old/scratchpad" ] && bad "main(): PROD=1 should allow the real launchd path to reap normally" || ok "main(): root==real-default + PROD=1 → reaps normally (opt-in respected)"

rm -rf "$SENTINEL_ROOT"

# Non-regression: a FIXTURE root (never equal to the real default) must reap
# normally with no PROD opt-in at all — the sentinel must never fire for
# ordinary test/tmp-fixture roots, only for the literal real-default value.
FIXTURE_ROOT="$(mktemp -d /tmp/scratchpad-reaper-selftest-fixture.XXXXXX)"
mkdir -p "$FIXTURE_ROOT/proj/dead-old/scratchpad"
touch -t "$OLD_TS" "$FIXTURE_ROOT/proj/dead-old/scratchpad"
SCRATCH_REAL_DEFAULT_ROOT="/private/tmp/claude-nonexistent-marker-$$"  # deliberately NOT $FIXTURE_ROOT
# shellcheck disable=SC2034  # read by main() in the sourced script
SCRATCH_ROOT="$FIXTURE_ROOT"
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
# shellcheck disable=SC2034  # read by main() in the sourced script
PROD=0
main
[ -d "$FIXTURE_ROOT/proj/dead-old/scratchpad" ] && bad "main(): fixture root (!= real default) must reap normally, sentinel must not fire" || ok "main(): fixture root (!= real default) → sentinel inactive, reaps normally (no regression)"
rm -rf "$FIXTURE_ROOT"

echo ""
echo "=== production constant sanity (ga-h565g) ==="
# Uses the value captured immediately after this file's ONLY source (top of
# file), before any scenario above overrode SCRATCH_REAL_DEFAULT_ROOT for
# hermetic testing — confirms the constant actually used in production is
# exactly the expected real default (catches drift between the
# default-resolution line and the sentinel-comparison constant).
[ "$PRODUCTION_REAL_DEFAULT_ROOT" = "/private/tmp/claude-$(id -u)" ] && ok "production constant: SCRATCH_REAL_DEFAULT_ROOT matches the expected real default path" || bad "production constant drifted: got '$PRODUCTION_REAL_DEFAULT_ROOT'"

echo ""
echo "=== _is_dead: extracted self+liveness primitive (ga-rjhfz) ==="
# ga-rjhfz factors _should_reap's self/liveness half out into _is_dead so the
# CRITICAL-pressure size-escape gate (below) can reuse the exact same ABSOLUTE
# check without duplicating it — pressure must never get its own, potentially
# looser, copy of this logic.
_is_dead "dead-session-9"  "$KEYFILE" ""               && ok "is_dead: dead, no self set → true"                                  || bad "dead+no-self should be dead"
_is_dead "alive-session-1" "$KEYFILE" ""                && bad "is_dead: live session must never be dead"                          || ok "is_dead: live session → false"
_is_dead "dead-session-9"  "$KEYFILE" "dead-session-9"  && bad "is_dead: CURRENT session id must never be dead"                     || ok "is_dead: self id → false (self-protection)"
_is_dead "alive-session-1" "$KEYFILE" "dead-session-9"  && bad "is_dead: unrelated self id must not change a live session's outcome" || ok "is_dead: self set but different id → still protected by liveness"

echo ""
echo "=== _should_reap_size_escape: ga-rjhfz CRITICAL-pressure large-dead-dir escape ==="
# Composes _is_dead (ABSOLUTE — self/liveness, identical to _should_reap's own
# gate) with its OWN age+size thresholds. Never widens self/liveness; only
# ever widens how STALE a dead dir needs to be, and only when it's also large.
# ga-7jtyqjy: the last argument is the size LIMIT in KB. It was an integer number of GB,
# which cannot say "10% of what is left on the disk"; the limit itself is worked out by
# _size_escape_limit_kb (own section below).
LARGE_KB=$(( 2 * 1024 * 1024 ))   # 2GB in KB, the static ceiling (default large_gb=2)
BIG=$(( LARGE_KB + 1024 ))        # just over 2GB
SMALL=$(( LARGE_KB - 1024 ))      # just under 2GB
CRIT_OLD=$(( NOW - 2*3600 ))      # 2h old — past a 1h critical_min_age_hours
CRIT_FRESH=$(( NOW - 30*60 ))     # 30min old — under a 1h critical_min_age_hours

_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 ""              "$BIG"      "$LARGE_KB" && ok "size_escape: dead + old-enough + large-enough → escape reap"                                    || bad "dead+2h+big should size-escape"
_should_reap_size_escape "alive-session-1" "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 ""              "$BIG"      "$LARGE_KB" && bad "size_escape: live session must NEVER escape-reap regardless of size/pressure"                  || ok "size_escape: live session → never (liveness absolute)"
_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 "dead-session-9" "$BIG"      "$LARGE_KB" && bad "size_escape: CURRENT session id must never escape-reap"                                        || ok "size_escape: self id → never (self-protection absolute)"
_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_FRESH" "$NOW" 1 ""              "$BIG"      "$LARGE_KB" && bad "size_escape: dead+large but younger than critical_min_age_hours must NOT escape"               || ok "size_escape: too fresh for critical window → not yet"
esc_refuses() {  # esc_refuses <what> <size_kb> <limit_kb>: refused AND silent — an explicit "no", not a `[` error that happens to be nonzero
  local out rc
  out="$(_should_reap_size_escape "dead-session-9" "$KEYFILE" "$CRIT_OLD" "$NOW" 1 "" "$2" "$3" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ] && ok "size_escape: $1 → refused, silently" || bad "size_escape: $1 must be refused with no output (rc=$rc out='$out')"
}
_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 ""              "$SMALL"    "$LARGE_KB" && bad "size_escape: dead+old-enough but under the limit must NOT escape"                              || ok "size_escape: too small → not eligible"
esc_refuses "empty/unreadable size_kb" "" "$LARGE_KB"
esc_refuses "non-numeric size_kb" "abc" "$LARGE_KB"
_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 ""              "$LARGE_KB" "$LARGE_KB" && ok "size_escape: exactly at the limit → eligible (inclusive)"                                      || bad "exactly at the limit should be inclusive"
# ga-7jtyqjy: a limit below 1GB (10% of a 2GB-free disk) is now expressible, and a limit that cannot be read never authorizes.
_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 ""              $(( 300*1024 )) $(( 200*1024 )) && ok "size_escape: 300MB against a 200MB limit → eligible (limit is in KB, not whole GB)"          || bad "300MB over a 200MB limit should reap"
_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 ""              $(( 199*1024 )) $(( 200*1024 )) && bad "size_escape: 199MB against a 200MB limit must NOT reap"                                      || ok "size_escape: 199MB against a 200MB limit → kept"
esc_refuses "empty limit (no limit is not 'no bar')" "$BIG" ""
esc_refuses "non-numeric limit" "$BIG" "abc"
esc_refuses "empty size_kb against a limit of 0 (an unreadable size beats 0 >= 0)" "" 0

echo ""
echo "=== ga-7jtyqjy: _size_escape_limit_kb — the CRITICAL size bar follows the FREE space ==="
# 08/11: avail 2.0GB, a dead scratchpad of 0.9GB, CRITICAL. LARGE_GB=2 is a fixed whole
# number of GB: 0.9GB, almost half of what was left, sat under that bar. limit = pct% of
# the free KB, never above the static LARGE_GB ceiling, never under the floor. Every check
# compares the PRINTED value (a missing function prints nothing and fails, it cannot pass
# by its exit code).
GB_KB=$(( 1024 * 1024 ))
chk_limit() {  # chk_limit <name> <want> <large_gb> <avail_kb> <pct> <floor_mb>
  local got
  declare -F _size_escape_limit_kb >/dev/null 2>&1 || { bad "limit_kb: $1 — _size_escape_limit_kb is not defined"; return; }
  got="$(_size_escape_limit_kb "$3" "$4" "$5" "$6")"
  [ "$got" = "$2" ] && ok "limit_kb: $1 → '$2'" || bad "limit_kb: $1 — want '$2' got '$got'"
}
chk_limit "2GB free, 10% → 209715KB (the incident: 0.9GB clears it)" 209715 2 $(( 2*GB_KB )) 10 10
chk_limit "8GB free, 10% → 838860KB (below the ceiling: follows the free space)" 838860 2 $(( 8*GB_KB )) 10 10
chk_limit "100GB free → clamped to the 2GB ceiling" $(( 2*GB_KB )) 2 $(( 100*GB_KB )) 10 10
chk_limit "20GB free, 10% = exactly the ceiling" $(( 2*GB_KB )) 2 $(( 20*GB_KB )) 10 10
chk_limit "ceiling follows LARGE_GB (1) when free space is plentiful" "$GB_KB" 1 $(( 100*GB_KB )) 10 10
chk_limit "pct 100 on 1GB free → 1GB (under the 2GB ceiling)" "$GB_KB" 2 "$GB_KB" 100 10
chk_limit "0KB free is a KNOWN zero → the floor (10MB), not 0 and not the ceiling" 10240 2 0 10 10
chk_limit "50MB free → 10% is 5MB, under the floor → 10MB" 10240 2 51200 10 10
chk_limit "floor is configurable (64MB)" 65536 2 0 10 64
chk_limit "floor 0 is honoured (operator's choice) → 0" 0 2 0 10 0
chk_limit "unreadable floor → default 10MB" 10240 2 0 10 abc
chk_limit "empty floor → default 10MB" 10240 2 0 10 ""
# Third state: free space (or the pct) that cannot be read leaves the OLD rule — the static ceiling — never 0, never the floor.
chk_limit "free space unreadable (empty) → static ceiling" $(( 2*GB_KB )) 2 "" 10 10
chk_limit "free space unreadable (text) → static ceiling" $(( 2*GB_KB )) 2 "abc" 10 10
chk_limit "pct 0 = relative rule OFF → static ceiling (kill switch)" $(( 2*GB_KB )) 2 "$GB_KB" 0 10
chk_limit "pct unreadable → static ceiling" $(( 2*GB_KB )) 2 "$GB_KB" "10%" 10
chk_limit "pct empty → static ceiling" $(( 2*GB_KB )) 2 "$GB_KB" "" 10
chk_limit "pct above 100 → static ceiling" $(( 2*GB_KB )) 2 "$GB_KB" 101 10
chk_limit "floor ABOVE the ceiling (4GB vs 2GB) → the floor wins: the larger bar is the safer one" 4194304 2 0 10 4096
chk_limit "ceiling unreadable (LARGE_GB) → NOTHING printed (no limit, never a number)" "" "" $(( 2*GB_KB )) 10 10
chk_limit "ceiling unreadable (text) → NOTHING printed" "" "2GB" $(( 2*GB_KB )) 10 10
[ "$(_kb_mb 209715)" = "204" ] && [ "$(_kb_mb 0)" = "0" ] && [ "$(_kb_mb "")" = "?" ] && [ "$(_kb_mb abc)" = "?" ] && ok "kb_mb: whole MB for the log; unreadable prints '?' (never 0)" || bad "kb_mb: got '$(_kb_mb 209715)' '$(_kb_mb 0)' '$(_kb_mb "")' '$(_kb_mb abc)'"

echo ""
echo "=== ga-7jtyqjy: _avail_kb — free space of the scratch volume (empty when df cannot say) ==="
got="$(_avail_kb /tmp)"
case "$got" in
  ''|*[!0-9]*) bad "_avail_kb(/tmp) did not return an integer (got: '$got')" ;;
  *) [ "$got" -gt 0 ] && ok "_avail_kb(/tmp) returns a positive integer KB ($got)" || bad "_avail_kb(/tmp) returned non-positive: $got" ;;
esac
got="$(_avail_kb "/nonexistent/path/$$/x")"
[ -z "$got" ] && ok "_avail_kb(nonexistent path) → '' (df failure is NOT a 0)" || bad "_avail_kb(nonexistent) got '$got'"
got="$(df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfs 100 50 - 50%% /\n'; }; _avail_kb /tmp)"
[ -z "$got" ] && ok "_avail_kb: a figure that is not a number → ''" || bad "_avail_kb(garbled df) got '$got'"
got="$(df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfs 100 100 0 100%% /\n'; }; _avail_kb /tmp)"
[ "$got" = "0" ] && ok "_avail_kb: a full disk reads as 0 — a real zero, distinct from unreadable" || bad "_avail_kb(full disk) got '$got'"

got="$(env -u SCRATCHPAD_REAPER_LARGE_GB -u SCRATCHPAD_REAPER_LARGE_PCT -u SCRATCHPAD_REAPER_LARGE_FLOOR_MB -u SCRATCHPAD_REAPER_GC_TIMEOUT_SECS SCRATCHPAD_REAPER_LIB=1 bash -c '. "$1" >/dev/null 2>&1; printf "%s/%s/%s/%s" "$LARGE_GB" "$LARGE_PCT" "$LARGE_FLOOR_MB" "$GC_TIMEOUT_SECS"' _ "$SCRIPT")"
[ "$got" = "2/10/10/150" ] && ok "defaults: ceiling 2GB / 10% of the free space / 10MB floor / 150s gc deadline" || bad "defaults drifted — large_gb/pct/floor_mb/gc_timeout = '$got'"

echo ""
echo "=== main(): ga-rjhfz size-escape under CRITICAL pressure (bead ACEITE criteria) ==="
# Hermetic: own fixture root (never the real default — sentinel stays
# inactive, same non-regression trick as the FIXTURE_ROOT scenario above),
# own liveness stub (toggle FAKE_LIVE_SID per scenario instead of the
# always-empty stub used by the sentinel section above), and _dir_size_kb
# STUBBED so multi-GB scenarios never touch real disk — a fixture dir is a
# few bytes on disk; only the stubbed return value claims it's 10GB.
PRESSURE_ROOT="$(mktemp -d /tmp/scratchpad-reaper-selftest-pressure.XXXXXX)"
SCRATCH_REAL_DEFAULT_ROOT="/private/tmp/claude-nonexistent-marker-ga-rjhfz-$$"
SCRATCH_ROOT="$PRESSURE_ROOT"
# shellcheck disable=SC2034  # read by main()/_should_reap in the sourced script
MIN_AGE_HOURS=24
# shellcheck disable=SC2034  # read by main()/_should_reap_size_escape in the sourced script
CRITICAL_MIN_AGE_HOURS=1
# shellcheck disable=SC2034  # read by main()/_should_reap_size_escape in the sourced script
LARGE_GB=2
# shellcheck disable=SC2034  # ga-7jtyqjy: read by main() (pinned so a caller's env cannot move these scenarios)
LARGE_PCT=10; LARGE_FLOOR_MB=10
# shellcheck disable=SC2034  # read by main() in the sourced script
ENABLED=1
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
# shellcheck disable=SC2034  # read by _prod_sentinel_active() in the sourced script
PROD=0
# shellcheck disable=SC2034  # read by main() in the sourced script
SELF_SESSION_ID=""

FAKE_LIVE_SID=""
_fetch_live_keys() {
  if [ -n "$FAKE_LIVE_SID" ]; then printf '%s\n' "$FAKE_LIVE_SID" > "$1"; else : > "$1"; fi
}
FAKE_SIZE_KB=""
_dir_size_kb() { printf '%s' "$FAKE_SIZE_KB"; }
# ga-7jtyqjy: free space of the scratch volume. Default 100GB = plenty free, so the limit
# is the static 2GB ceiling and every legacy scenario below keeps its old meaning whatever
# the host's disk looks like. The counter file survives the $( ) subshell.
FAKE_AVAIL_KB=$(( 100 * 1024 * 1024 )); AVAIL_CALLS="$PRESSURE_ROOT/.avail-calls"
_avail_kb() { echo x >> "$AVAIL_CALLS"; printf '%s' "$FAKE_AVAIL_KB"; }

make_pressure_fixture() {  # make_pressure_fixture <sid> <touch_ts>
  rm -rf "$PRESSURE_ROOT/proj/$1"
  mkdir -p "$PRESSURE_ROOT/proj/$1/scratchpad"
  touch -t "$2" "$PRESSURE_ROOT/proj/$1/scratchpad"
}
TS_3H30="$(date -v-3H -v-30M +%Y%m%d%H%M.%S)"   # dead+3.5h: too fresh for MIN_AGE_HOURS=24, old enough for critical(1h)
TS_10MIN="$(date -v-10M +%Y%m%d%H%M.%S)"        # dead+10min: too fresh even for the critical window

# ACEITE #1 — the incident itself: dead, ~10GB, 3.5h old, CRITICAL pressure →
# today's code leaves this stuck behind the 24h gate; the fix must free it.
make_pressure_fixture "dead-big" "$TS_3H30"
FAKE_LIVE_SID=""; FAKE_SIZE_KB=$(( 10 * 1024 * 1024 )); PRESSURE=CRITICAL
main
[ -d "$PRESSURE_ROOT/proj/dead-big/scratchpad" ] && bad "ACEITE#1: dead+10G+3.5h under CRITICAL should be REAPED, but it survived" || ok "ACEITE#1: dead+10G+3.5h under CRITICAL pressure → reaped (size-escape)"

# ACEITE #2 — identical dir, but the session is LIVE: pressure must NEVER
# matter. This is the only proof that liveness wasn't loosened along with age.
make_pressure_fixture "live-big" "$TS_3H30"
FAKE_LIVE_SID="live-big"; FAKE_SIZE_KB=$(( 10 * 1024 * 1024 )); PRESSURE=CRITICAL
main
[ -d "$PRESSURE_ROOT/proj/live-big/scratchpad" ] && ok "ACEITE#2: LIVE session's 10G/3.5h dir survives CRITICAL pressure (liveness never loosened)" || bad "ACEITE#2: REGRESSION — a LIVE session's scratchpad was reaped under pressure"

# Same proof for the OTHER absolute gate: the caller's own current session.
make_pressure_fixture "self-big" "$TS_3H30"
FAKE_LIVE_SID=""; SELF_SESSION_ID="self-big"; FAKE_SIZE_KB=$(( 10 * 1024 * 1024 )); PRESSURE=CRITICAL
main
# shellcheck disable=SC2034  # read by main() in the sourced script
SELF_SESSION_ID=""
[ -d "$PRESSURE_ROOT/proj/self-big/scratchpad" ] && ok "ACEITE#2b: CURRENT session's own 10G/3.5h dir survives CRITICAL pressure (self-protection never loosened)" || bad "ACEITE#2b: REGRESSION — the caller's OWN session scratchpad was reaped under pressure"

# ACEITE #3 — same dead+10G+3.5h dir, but no CRITICAL signal at all (ordinary
# WARN or a manual/non-guard invocation) → behavior outside CRITICAL is
# byte-identical to before ga-rjhfz: too fresh for 24h, survives.
make_pressure_fixture "dead-big-nopressure" "$TS_3H30"
FAKE_LIVE_SID=""; FAKE_SIZE_KB=$(( 10 * 1024 * 1024 )); PRESSURE=""
main
[ -d "$PRESSURE_ROOT/proj/dead-big-nopressure/scratchpad" ] && ok "ACEITE#3: outside CRITICAL pressure, dead+10G+3.5h survives — 24h behavior unchanged (no regression)" || bad "ACEITE#3: REGRESSION — reaped a fresh dir with no pressure signal"

# WARN specifically (not just unset) must not get the escape either — the
# bead scopes the widened gate to CRITICAL only.
make_pressure_fixture "dead-big-warn" "$TS_3H30"
FAKE_LIVE_SID=""; FAKE_SIZE_KB=$(( 10 * 1024 * 1024 )); PRESSURE="WARN"
main
[ -d "$PRESSURE_ROOT/proj/dead-big-warn/scratchpad" ] && ok "ACEITE#3b: WARN pressure (not CRITICAL) does not get the size-escape either" || bad "ACEITE#3b: REGRESSION — WARN pressure reaped a fresh dir (escape must be CRITICAL-only)"

# Dead + old enough + CRITICAL, but under LARGE_GB → still survives.
make_pressure_fixture "dead-small" "$TS_3H30"
FAKE_LIVE_SID=""; FAKE_SIZE_KB=$(( 500 * 1024 )); PRESSURE=CRITICAL
main
[ -d "$PRESSURE_ROOT/proj/dead-small/scratchpad" ] && ok "size_escape: dead+500MB+3.5h under CRITICAL survives (too small for LARGE_GB=2)" || bad "REGRESSION — reaped a small dir under the size-escape"

# Dead + large + CRITICAL, but younger than CRITICAL_MIN_AGE_HOURS → survives
# (the escape still needs SOME age buffer — protects a session that died
# moments ago from being reaped before its death has even settled).
make_pressure_fixture "dead-fresh" "$TS_10MIN"
FAKE_LIVE_SID=""; FAKE_SIZE_KB=$(( 10 * 1024 * 1024 )); PRESSURE=CRITICAL
main
[ -d "$PRESSURE_ROOT/proj/dead-fresh/scratchpad" ] && ok "size_escape: dead+10G+10min under CRITICAL survives (younger than critical_min_age_hours=1)" || bad "REGRESSION — reaped a 10-minute-old dir under the size-escape"

echo ""
echo "=== main(): ga-7jtyqjy — the CRITICAL size bar follows the free space (the 08/11 incident) ==="
# 08/11 ~10:00: 2.0GB free; a dead wa-worker's scratchpad of 923MB (13 repo copies) sat
# there and the fixed 2GB bar passed it by, nearly half of everything left. Same shape
# here; sizes and free space are stubbed (a fixture dir is a few bytes on disk).
INC_LOG="$(mktemp /tmp/scratchpad-reaper-selftest-inclog.XXXXXX)"; SAVED_LOG="$LOG"; LOG="$INC_LOG"
KB_INC=$(( 923 * 1024 )); KB_2GB=$(( 2 * 1024 * 1024 ))
FAKE_AVAIL_AFTER_FIRST=""
_avail_kb() { local n; echo x >> "$AVAIL_CALLS"; n=$(( $(wc -l < "$AVAIL_CALLS") )); if [ "$n" -gt 1 ] && [ -n "$FAKE_AVAIL_AFTER_FIRST" ]; then printf '%s' "$FAKE_AVAIL_AFTER_FIRST"; else printf '%s' "$FAKE_AVAIL_KB"; fi; }
inc() {  # inc <sid> <touch_ts> <size_kb> <avail_kb> <pressure>: one cycle over ONE dead dir (nothing left from earlier scenes)
  rm -rf "$PRESSURE_ROOT/proj"; make_pressure_fixture "$1" "$2"
  FAKE_LIVE_SID=""; FAKE_SIZE_KB="$3"; FAKE_AVAIL_KB="$4"; PRESSURE="$5"; : > "$INC_LOG"; : > "$AVAIL_CALLS"
  main
}
gone() { [ ! -d "$PRESSURE_ROOT/proj/$1/scratchpad" ]; }

inc dead-incident "$TS_3H30" "$KB_INC" "$KB_2GB" CRITICAL
gone dead-incident && ok "INCIDENT: dead + 923MB + 3.5h, 2GB free, CRITICAL → reaped (the bar is 10% of the free space, not a fixed 2GB)" || bad "INCIDENT: the 923MB dead scratchpad survived with 2GB free under CRITICAL"
grep -q "reaped (size-escape): proj/dead-incident/scratchpad" "$INC_LOG" && ok "INCIDENT: the log names the reap and its reason (the proof the bead asks for)" || bad "INCIDENT: no 'reaped (size-escape)' line — got: $(cat "$INC_LOG")"
inc dead-below "$TS_3H30" $(( 150 * 1024 )) "$KB_2GB" CRITICAL
{ ! gone dead-below && grep -q "dead-below" "$INC_LOG"; } && ok "BAR: 150MB with 2GB free (bar 204MB) survives — small dead dirs are not swept just because the disk is CRITICAL" || bad "BAR: a 150MB dir fell under a 204MB bar — got: $(cat "$INC_LOG")"
grep -q "candidato morto PULADO: proj/dead-below.*size_limit=204MB avail=2048MB" "$INC_LOG" && ok "BAR: the skip line carries the limit AND the free space it came from (nobody re-derives it by hand)" || bad "BAR: PULADO line lacks size_limit=204MB avail=2048MB — got: $(cat "$INC_LOG")"
grep -q "nada elegivel.*size_limit=204MB avail=2048MB" "$INC_LOG" && ok "BAR: so does the cycle summary" || bad "BAR: nada-elegivel summary lacks size_limit=204MB avail=2048MB — got: $(cat "$INC_LOG")"
inc dead-at-bar "$TS_3H30" 209715 "$KB_2GB" CRITICAL
gone dead-at-bar && ok "BAR: exactly at the limit (209715KB) → reaped (inclusive)" || bad "BAR: a dir exactly at the limit survived"
inc dead-under-bar "$TS_3H30" 209714 "$KB_2GB" CRITICAL
gone dead-under-bar && bad "BAR: one KB under the limit was reaped" || ok "BAR: one KB under the limit → kept"
inc dead-ample "$TS_3H30" "$KB_INC" $(( 100 * 1024 * 1024 )) CRITICAL
gone dead-ample && bad "CEILING: with 100GB free the bar must stay at the 2GB ceiling, but 923MB was reaped" || ok "CEILING: plenty of space free (100GB) → 923MB kept, the old 2GB bar still applies"

# The env knobs reach the right slots (pct and floor are both 10 by default, so only different values can tell them apart).
LARGE_PCT=20
inc dead-pct20-under "$TS_3H30" 419429 "$KB_2GB" CRITICAL
gone dead-pct20-under && bad "KNOBS: pct 20 of 2GB free is a 419430KB bar, but 419429KB was reaped" || ok "KNOBS: LARGE_PCT=20 → bar 419430KB (one KB under is kept)"
inc dead-pct20-at "$TS_3H30" 419430 "$KB_2GB" CRITICAL
LARGE_PCT=10
gone dead-pct20-at && ok "KNOBS: LARGE_PCT=20 → 419430KB is reaped" || bad "KNOBS: a dir at the 20% bar survived"
LARGE_FLOOR_MB=64
inc dead-floor64-under "$TS_3H30" $(( 64*1024 - 1 )) 0 CRITICAL
gone dead-floor64-under && bad "KNOBS: LARGE_FLOOR_MB=64 at 0 free is a 65536KB bar, but 65535KB was reaped" || ok "KNOBS: LARGE_FLOOR_MB=64 at 0KB free → bar 64MB (one KB under is kept)"
inc dead-floor64-at "$TS_3H30" $(( 64*1024 )) 0 CRITICAL
LARGE_FLOOR_MB=10
gone dead-floor64-at && ok "KNOBS: LARGE_FLOOR_MB=64 → a 64MB dir is reaped" || bad "KNOBS: a dir at the 64MB floor survived"
LARGE_GB=1
inc dead-ceil1 "$TS_3H30" $(( 1536 * 1024 )) $(( 100 * 1024 * 1024 )) CRITICAL
LARGE_GB=2
gone dead-ceil1 && ok "KNOBS: LARGE_GB=1 is the ceiling → 1.5GB dead dir reaped with 100GB free" || bad "KNOBS: LARGE_GB=1 did not become the ceiling"

# Third state: a free-space reading that failed keeps the OLD rule (static 2GB) and says so — it is neither 0 nor 'everything'.
inc dead-noavail "$TS_3H30" "$KB_INC" "" CRITICAL
{ ! gone dead-noavail && grep -q "size_limit=2048MB" "$INC_LOG" && grep -q "WARN: .*free space" "$INC_LOG"; } && ok "UNREADABLE: free space unknown → the static 2GB bar stays, with a WARN naming it" || bad "UNREADABLE: unknown free space mishandled — got: $(cat "$INC_LOG")"
inc dead-zero "$TS_3H30" "$KB_INC" 0 CRITICAL
gone dead-zero && ok "ZERO FREE: a full disk is a KNOWN 0 (not 'unreadable') → the floor bar, 923MB reaped" || bad "ZERO FREE: with 0KB free the dir survived"
LARGE_FLOOR_MB=0
inc dead-nosize "$TS_3H30" "" 0 CRITICAL
LARGE_FLOOR_MB=10
{ ! gone dead-nosize; } && ok "UNREADABLE SIZE: du said nothing and the bar is 0 → kept (an unreadable size is never read as 0 against a 0 bar)" || bad "UNREADABLE SIZE: a dir whose size could not be read was reaped"

# Everything that is NOT size stays absolute at the new, lower bar.
inc dead-nopress "$TS_3H30" "$KB_INC" "$KB_2GB" ""
{ ! gone dead-nopress && [ ! -s "$AVAIL_CALLS" ]; } && ok "NO PRESSURE: same dir without the CRITICAL signal → kept, and free space is not even read" || bad "NO PRESSURE: reaped (or df read) without a CRITICAL signal"
inc dead-warn "$TS_3H30" "$KB_INC" "$KB_2GB" WARN
gone dead-warn && bad "WARN: only CRITICAL widens the bar" || ok "WARN: pressure WARN does not get the lower bar"
inc dead-young "$TS_10MIN" "$KB_INC" "$KB_2GB" CRITICAL
gone dead-young && bad "AGE: a 10-minute-old dir was reaped at the lower bar" || ok "AGE: dead + 923MB but 10min old → kept (critical_min_age_hours unchanged)"
rm -rf "$PRESSURE_ROOT/proj"; make_pressure_fixture live-mid "$TS_3H30"
FAKE_LIVE_SID="live-mid"; FAKE_SIZE_KB="$KB_INC"; FAKE_AVAIL_KB="$KB_2GB"; PRESSURE=CRITICAL; main
gone live-mid && bad "LIVENESS: a LIVE session's 923MB dir was reaped at the lower bar" || ok "LIVENESS: live session + 923MB under CRITICAL → kept (liveness never loosened)"
rm -rf "$PRESSURE_ROOT/proj"; make_pressure_fixture self-mid "$TS_3H30"
FAKE_LIVE_SID=""; SELF_SESSION_ID="self-mid"; main; SELF_SESSION_ID=""
gone self-mid && bad "SELF: the caller's own 923MB dir was reaped at the lower bar" || ok "SELF: the caller's own session + 923MB under CRITICAL → kept (self-protection never loosened)"

# One reading per cycle: reaping frees space, and a bar that rose mid-cycle would keep the
# second 923MB dir that the first one's reap made possible to keep. Free space is 2GB for
# the first read and 100GB for any later one.
rm -rf "$PRESSURE_ROOT/proj"; make_pressure_fixture dead-a "$TS_3H30"; make_pressure_fixture dead-b "$TS_3H30"
FAKE_LIVE_SID=""; FAKE_SIZE_KB="$KB_INC"; FAKE_AVAIL_KB="$KB_2GB"; FAKE_AVAIL_AFTER_FIRST=$(( 100 * 1024 * 1024 )); PRESSURE=CRITICAL; : > "$AVAIL_CALLS"
main
FAKE_AVAIL_AFTER_FIRST=""
{ gone dead-a && gone dead-b && [ "$(wc -l < "$AVAIL_CALLS" | tr -d ' ')" = "1" ]; } && ok "SNAPSHOT: free space is read ONCE per cycle — both 923MB dirs face the same bar" || bad "SNAPSHOT: bar moved mid-cycle (reads=$(wc -l < "$AVAIL_CALLS" | tr -d ' '), a-gone=$(gone dead-a && echo y || echo n), b-gone=$(gone dead-b && echo y || echo n))"
rm -rf "$PRESSURE_ROOT/proj"; LOG="$SAVED_LOG"; rm -f "$INC_LOG"   # nothing left behind for the next section, pass or fail

echo ""
echo "=== main(): skip-logging + cycle-summary distinguish nada-elegivel from nada-encontrado (ga-rjhfz) ==="
# The real incident's mail said "cleanup was already attempted" when 10GB of
# genuinely-dead data existed but wasn't eligible — "tried and found nothing"
# and "tried and nothing qualified" collapsed into the same silence. These
# assertions are the log-level half of the fix: a dead-but-ineligible
# candidate must be named explicitly (not silently skipped), and the cycle
# summary must use different words for "nothing was even dead" vs "something
# was dead but none qualified".
SKIP_LOG="$(mktemp /tmp/scratchpad-reaper-selftest-skiplog.XXXXXX)"
# shellcheck disable=SC2034  # read by log() in the sourced script
LOG="$SKIP_LOG"

make_pressure_fixture "dead-fresh2" "$TS_10MIN"
: > "$SKIP_LOG"
FAKE_LIVE_SID=""; FAKE_SIZE_KB=$(( 10 * 1024 * 1024 ))
# shellcheck disable=SC2034  # read by main() in the sourced script
PRESSURE=CRITICAL
main
if grep -q "PULADO" "$SKIP_LOG" && grep -q "dead-fresh2" "$SKIP_LOG"; then
  ok "skip-log: dead-but-ineligible candidate gets an explicit PULADO line (not silent)"
else
  bad "skip-log: no explicit PULADO line for a dead-but-ineligible candidate — got: $(cat "$SKIP_LOG")"
fi
if grep -q "nada elegivel" "$SKIP_LOG"; then
  ok "cycle-summary: candidates found but none eligible → reports 'nada elegivel' explicitly"
else
  bad "cycle-summary: did not distinguish 'nada elegivel' — got: $(cat "$SKIP_LOG")"
fi

EMPTY_ROOT="$(mktemp -d /tmp/scratchpad-reaper-selftest-empty.XXXXXX)"
# shellcheck disable=SC2034  # read by main() in the sourced script
SCRATCH_ROOT="$EMPTY_ROOT"
: > "$SKIP_LOG"
main
if grep -q "nada encontrado" "$SKIP_LOG" && ! grep -q "nada elegivel" "$SKIP_LOG"; then
  ok "cycle-summary: empty root → reports 'nada encontrado', distinct from 'nada elegivel'"
else
  bad "cycle-summary: empty root did not report 'nada encontrado' distinctly — got: $(cat "$SKIP_LOG")"
fi
rm -rf "$EMPTY_ROOT" "$PRESSURE_ROOT" "$SKIP_LOG"

# ════════════════════════════════════════════════════════════════════════════
# ga-hynohs — ALWAYS-ON SWEEP. Incident (Mayor, 2026-09-26): gate reviewers'
# scratchpads (git-archive copies of a branch, 130-830MB each) piled up to
# 2.4GB in 3h because the ONLY age gate was 24h and the ONLY early exit was
# CRITICAL pressure + a single dir >= 2GB — a reviewer copy never qualifies
# for either. The sweep adds a third path: dead AND idle >= MIN_IDLE_MINUTES,
# with no pressure signal at all. Everything that keeps a session's scratch
# safe (self, gc liveness, process liveness, project protection, fail-closed
# on any unknowable input) must hold on that path exactly as on the others.
# ════════════════════════════════════════════════════════════════════════════
age_ts() { date -v-"$1"M +%Y%m%d%H%M.%S; }   # age_ts <minutes> → touch -t stamp

echo ""
echo "=== ga-hynohs: _is_idle_minutes ==="
NOW=1000000
_is_idle_minutes $(( NOW - 31*60 )) "$NOW" 30 && ok "is_idle_minutes: 31min idle, min 30 → idle"                         || bad "31min should be idle at min=30"
_is_idle_minutes $(( NOW - 30*60 )) "$NOW" 30 && ok "is_idle_minutes: exactly 30min → idle (boundary inclusive)"          || bad "30min boundary should be inclusive"
_is_idle_minutes $(( NOW - 29*60 )) "$NOW" 30 && bad "is_idle_minutes: 29min must NOT be idle yet"                        || ok "is_idle_minutes: 29min → not idle"
_is_idle_minutes $(( NOW - 999*60 )) "$NOW" 0  && bad "is_idle_minutes: min=0 must DISABLE the gate, not mean 'always idle'" || ok "is_idle_minutes: min=0 → disabled (legacy callers unaffected)"
_is_idle_minutes $(( NOW - 999*60 )) "$NOW" "" && bad "is_idle_minutes: empty min must disable the gate"                   || ok "is_idle_minutes: empty min → disabled"
_is_idle_minutes $(( NOW - 999*60 )) "$NOW" abc && bad "is_idle_minutes: non-numeric min must disable the gate"             || ok "is_idle_minutes: non-numeric min → disabled"
_is_idle_minutes "" "$NOW" 30                   && bad "is_idle_minutes: unreadable mtime must NEVER authorize deletion"    || ok "is_idle_minutes: empty mtime → false (fail toward keep)"
_is_idle_minutes abc "$NOW" 30                  && bad "is_idle_minutes: non-numeric mtime must NEVER authorize deletion"   || ok "is_idle_minutes: non-numeric mtime → false"

echo ""
echo "=== ga-hynohs: session-id extraction + project-dir encoding ==="
U1="0a1b2c3d-1111-4222-8333-444455556666"
U2="9f8e7d6c-aaaa-4bbb-8ccc-ddddeeeeffff"
got="$(printf '%s' "claude --dangerously-skip-permissions --session-id $U1 -r $U2" | _extract_uuids | sort | tr '\n' ' ')"
[ "$got" = "$U1 $U2 " ] && ok "extract_uuids: --session-id and -r values both found" || bad "extract_uuids: got '$got'"
got="$(printf '%s' "claude --session-id=$U1 --resume $U2" | _extract_uuids | sort | tr '\n' ' ')"
[ "$got" = "$U1 $U2 " ] && ok "extract_uuids: --flag=value form and --resume found (flag-agnostic)" || bad "extract_uuids (=form): got '$got'"
got="$(printf '%s' "claude --dangerously-skip-permissions --model opus" | _extract_uuids)"
[ -z "$got" ] && ok "extract_uuids: a command line with no uuid yields nothing" || bad "extract_uuids: invented '$got'"
got="$(printf '%s' "claude --session-id 0A1B2C3D-1111-4222-8333-444455556666" | _extract_uuids)"
[ "$got" = "$U1" ] && ok "extract_uuids: upper-case uuid normalised to the lower-case form the scratchpad dirs use" || bad "extract_uuids case: got '$got'"
got="$(_encode_project_dir "/Users/athos/gt/.gascity-gastown-hq")"
[ "$got" = "-Users-athos-gt--gascity-gastown-hq" ] && ok "encode_project_dir: '/' and '.' both become '-' (matches the real project dir name)" || bad "encode_project_dir: got '$got'"
got="$(_encode_project_dir "/Users/athos/gt/whatsapp_automation/crew/batista")"
[ "$got" = "-Users-athos-gt-whatsapp-automation-crew-batista" ] && ok "encode_project_dir: '_' becomes '-' too" || bad "encode_project_dir underscore: got '$got'"

echo ""
echo "=== ga-hynohs: _ps_claude_lines (fake ps on PATH) ==="
FAKEBIN="$(mktemp -d /tmp/scratchpad-reaper-selftest-bin.XXXXXX)"
cat > "$FAKEBIN/ps" <<'PSEOF'
#!/bin/bash
case "${FAKE_PS_MODE:-ok}" in
  fail)  exit 1 ;;
  empty) exit 0 ;;
esac
cat <<'OUT'
    1 /sbin/launchd
  101 claude --dangerously-skip-permissions --session-id 0a1b2c3d-1111-4222-8333-444455556666
  102 /Users/athos/.local/bin/claude --settings {"a":"*"} --resume 9f8e7d6c-aaaa-4bbb-8ccc-ddddeeeeffff
  103 /bin/zsh -c source /Users/athos/.claude/shell-snapshots/snapshot.sh && eval claude
  104 bash /Users/athos/gt/x/claude-lowprio.sh --session-id 77777777-7777-4777-8777-777777777777
  105 grep claude
OUT
PSEOF
chmod +x "$FAKEBIN/ps"
got="$(PATH="$FAKEBIN:$PATH" _ps_claude_lines | awk '{print $1}' | tr '\n' ' ')"
[ "$got" = "101 102 " ] && ok "ps_claude_lines: keeps only processes whose EXECUTABLE is claude (not zsh/bash/grep that merely mention it)" || bad "ps_claude_lines: got pids '$got'"
FAKE_PS_MODE=fail PATH="$FAKEBIN:$PATH" _ps_claude_lines >/dev/null && bad "ps_claude_lines: a failing ps must be an ERROR, not an empty list" || ok "ps_claude_lines: ps failure → nonzero (never 'no claude running')"
FAKE_PS_MODE=empty PATH="$FAKEBIN:$PATH" _ps_claude_lines >/dev/null && bad "ps_claude_lines: ps that prints nothing at all must be an ERROR (a live machine always has processes)" || ok "ps_claude_lines: totally empty ps output → nonzero"

echo ""
echo "=== ga-hynohs: _fetch_proc_liveness (three states: ids / unknown / nobody) ==="
eval "$REAL_PROC_FN"
PL_KEYS="$(mktemp /tmp/scratchpad-reaper-selftest-plk.XXXXXX)"
PL_PROJS="$(mktemp /tmp/scratchpad-reaper-selftest-plp.XXXXXX)"
LOG="$(mktemp /tmp/scratchpad-reaper-selftest-pllog.XXXXXX)"
_pid_cwd() { echo "/must/not/be/asked"; }
_ps_claude_lines() { printf '%s\n' "  101 claude --dangerously-skip-permissions --session-id $U1" "  102 claude --settings {} -r $U2"; }
: > "$PL_KEYS"; : > "$PL_PROJS"
_fetch_proc_liveness "$PL_KEYS" "$PL_PROJS"; rc=$?
[ "$rc" -eq 0 ] && grep -qxF "$U1" "$PL_KEYS" && grep -qxF "$U2" "$PL_KEYS" && ok "proc_liveness: --session-id and -r ids of running claude processes land in the live set" || bad "proc_liveness: ids missing (rc=$rc keys=$(cat "$PL_KEYS"))"
[ ! -s "$PL_PROJS" ] && ok "proc_liveness: identified processes protect no project dir (their id already protects them)" || bad "proc_liveness: identified process leaked a project protection"

_ps_claude_lines() { echo "  103 claude"; }
_pid_cwd() { echo "/Users/athos/gt/.gascity-gastown-hq"; }
: > "$PL_KEYS"; : > "$PL_PROJS"
_fetch_proc_liveness "$PL_KEYS" "$PL_PROJS"; rc=$?
[ "$rc" -eq 0 ] && grep -qxF -- "-Users-athos-gt--gascity-gastown-hq" "$PL_PROJS" && ok "proc_liveness: a claude with NO session id (interactive/--continue) protects the project dir of its cwd" || bad "proc_liveness: unidentified claude did not protect its project (rc=$rc projs=$(cat "$PL_PROJS"))"

_pid_cwd() { return 1; }
: > "$PL_KEYS"; : > "$PL_PROJS"
_fetch_proc_liveness "$PL_KEYS" "$PL_PROJS" && bad "proc_liveness: an unidentified claude whose cwd is unreadable must ABORT (we cannot tell what it owns)" || ok "proc_liveness: unidentified claude + unreadable cwd → nonzero (cycle aborts, nothing reaped)"

_ps_claude_lines() { return 1; }
_fetch_proc_liveness "$PL_KEYS" "$PL_PROJS" && bad "proc_liveness: ps failure must ABORT — 'could not look' is not 'nobody is running'" || ok "proc_liveness: ps failure → nonzero"

_ps_claude_lines() { return 0; }
: > "$PL_KEYS"; : > "$PL_PROJS"
_fetch_proc_liveness "$PL_KEYS" "$PL_PROJS"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$PL_KEYS" ] && ok "proc_liveness: ps fine and genuinely no claude running → success with an empty set (quiet town is not an error)" || bad "proc_liveness: quiet town mis-handled (rc=$rc)"
rm -f "$PL_KEYS" "$PL_PROJS"

echo ""
echo "=== ga-hynohs: main() — always-on idle sweep ==="
IDLE_ROOT="$(mktemp -d /tmp/scratchpad-reaper-selftest-idle.XXXXXX)"
IDLE_LOG="$(mktemp /tmp/scratchpad-reaper-selftest-idlelog.XXXXXX)"
# shellcheck disable=SC2034  # all read by main() in the sourced script
{
  SCRATCH_REAL_DEFAULT_ROOT="/private/tmp/claude-nonexistent-marker-ga-hynohs-$$"
  SCRATCH_ROOT="$IDLE_ROOT"; LOG="$IDLE_LOG"
  MIN_AGE_HOURS=24; MIN_IDLE_MINUTES=30; PRESSURE=""
  ENABLED=1; DRY_RUN=0; PROD=0; SELF_SESSION_ID=""
  FAKE_LIVE_SID=""; FAKE_SIZE_KB=$(( 210 * 1024 ))   # one reviewer tree copy, ~210MB
}
FAKE_PROC_KEYS=""; FAKE_PROC_PROJS=""; FAKE_PROC_RC=0
_fetch_proc_liveness() {
  [ "$FAKE_PROC_RC" -eq 0 ] || return 1
  [ -z "$FAKE_PROC_KEYS" ]  || printf '%s\n' "$FAKE_PROC_KEYS"  >> "$1"
  [ -z "$FAKE_PROC_PROJS" ] || printf '%s\n' "$FAKE_PROC_PROJS" >> "$2"
  return 0
}
_remove_scratchpad() { rm -rf "$1"; }
make_idle_fixture() {  # make_idle_fixture <proj> <sid> <age_minutes>
  rm -rf "$IDLE_ROOT/$1/$2"
  mkdir -p "$IDLE_ROOT/$1/$2/scratchpad/tree"
  : > "$IDLE_ROOT/$1/$2/scratchpad/tree/copy.txt"
  touch -t "$(age_ts "$3")" "$IDLE_ROOT/$1/$2/scratchpad"
}
fx() { echo "$IDLE_ROOT/$1/$2/scratchpad"; }

# THE INCIDENT, and its guard rails, in one cycle. Nothing here is under
# pressure and nothing is >= 2GB: exactly the shape the old gates ignore.
make_idle_fixture gate dead-idle-45m 45
make_idle_fixture gate dead-fresh-10m 10
make_idle_fixture gate live-gc-45m 45
make_idle_fixture gate live-proc-45m 45
make_idle_fixture gate self-45m 45
make_idle_fixture protproj dead-in-protected-project-45m 45
make_idle_fixture otherproj dead-idle-45m 45
FAKE_LIVE_SID="live-gc-45m"; FAKE_PROC_KEYS="live-proc-45m"; FAKE_PROC_PROJS="protproj"; SELF_SESSION_ID="self-45m"
: > "$IDLE_LOG"
main
SELF_SESSION_ID=""
[ -d "$(fx gate dead-idle-45m)" ] && bad "SWEEP: a DEAD scratchpad idle for 45min (no pressure, well under 2GB) must be reaped — it survived, exactly the ga-hynohs leak" || ok "SWEEP: dead + idle 45min (>= 30) → reaped with no pressure signal at all"
[ -d "$(fx otherproj dead-idle-45m)" ] && bad "SWEEP: same-shape dir in an UNPROTECTED project must be reaped too (project protection must not be global)" || ok "SWEEP: an unrelated project's dead idle scratchpad is reaped (project protection is scoped)"
[ -d "$(fx gate dead-fresh-10m)" ] && ok "SWEEP: dead but only 10min idle → kept (grace for a session that just died)" || bad "SWEEP: REGRESSION — reaped a 10min-old dead scratchpad"
[ -d "$(fx gate live-gc-45m)" ] && ok "SWEEP: session in gc session list → kept (liveness never loosened by the idle path)" || bad "SWEEP: REGRESSION — reaped a gc-live session's scratchpad"
[ -d "$(fx gate live-proc-45m)" ] && ok "SWEEP: session live only as a running claude process → kept (process liveness respected)" || bad "SWEEP: REGRESSION — reaped a scratchpad whose claude process is running"
[ -d "$(fx gate self-45m)" ] && ok "SWEEP: the caller's own session → kept (self-protection never loosened)" || bad "SWEEP: REGRESSION — reaped the caller's OWN scratchpad"
[ -d "$(fx protproj dead-in-protected-project-45m)" ] && ok "SWEEP: dead dir inside a project owned by an unidentified running claude → kept" || bad "SWEEP: REGRESSION — reaped inside a project protected by a session-id-less claude"
[ -d "$IDLE_ROOT/gate/dead-idle-45m" ] && ok "SWEEP: only the scratchpad LEAF goes — the session dir itself stays" || bad "SWEEP: session dir was removed along with the leaf"
grep -q "reaped (idle)" "$IDLE_LOG" && ok "SWEEP: log names the reason 'idle'" || bad "SWEEP: log missing 'reaped (idle)' — got: $(cat "$IDLE_LOG")"
grep -q "elapsed=" "$IDLE_LOG" && ok "SWEEP: cycle summary carries elapsed= (run duration is measurable from the log alone)" || bad "SWEEP: no elapsed= in the summary — got: $(cat "$IDLE_LOG")"
grep -q "live_ids=2 protected_projects=1" "$IDLE_LOG" && ok "SWEEP: summary reports the liveness-set size (2 live ids, 1 protected project) — a project silenced by an id-less claude is visible" || bad "SWEEP: summary lacks live_ids/protected_projects — got: $(cat "$IDLE_LOG")"

# FAIL-CLOSED: a process scan that cannot be trusted aborts the WHOLE cycle —
# including the legacy 24h path, which shares the same liveness set.
make_idle_fixture gate dead-idle-45m 45
make_idle_fixture gate dead-old-48h $(( 48*60 ))
FAKE_LIVE_SID=""; FAKE_PROC_KEYS=""; FAKE_PROC_PROJS=""; FAKE_PROC_RC=1
: > "$IDLE_LOG"
main; rc=$?
FAKE_PROC_RC=0
{ [ -d "$(fx gate dead-idle-45m)" ] && [ -d "$(fx gate dead-old-48h)" ]; } && ok "FAIL-CLOSED: process scan failed → NOTHING reaped (idle nor 24h path)" || bad "FAIL-CLOSED: a failed process scan still let a reap through"
[ "$rc" -ne 0 ] && grep -q "skipping reap cycle entirely" "$IDLE_LOG" && ok "FAIL-CLOSED: aborted cycle exits nonzero and says so in the log" || bad "FAIL-CLOSED: silent abort (rc=$rc) — got: $(cat "$IDLE_LOG")"

# LEGACY UNCHANGED: with the idle gate off (default), 45min stays — the
# disk-floor guard's own call path behaves exactly as before ga-hynohs.
MIN_IDLE_MINUTES=0
make_idle_fixture gate dead-idle-45m 45
make_idle_fixture gate dead-old-48h $(( 48*60 ))
main
[ -d "$(fx gate dead-idle-45m)" ] && ok "LEGACY: MIN_IDLE_MINUTES=0 → a 45min dead scratchpad is still kept (guard path unchanged)" || bad "LEGACY: REGRESSION — idle path fired while disabled"
[ -d "$(fx gate dead-old-48h)" ] && bad "LEGACY: the 24h age path must still reap a 48h dead dir" || ok "LEGACY: 24h age path still reaps a 48h dead dir"
MIN_IDLE_MINUTES=30

# DRY-RUN: decides, logs, deletes nothing.
make_idle_fixture gate dead-idle-45m 45
DRY_RUN=1; : > "$IDLE_LOG"
main
DRY_RUN=0
[ -d "$(fx gate dead-idle-45m)" ] && grep -q "DRY-RUN would reap (idle)" "$IDLE_LOG" && ok "DRY-RUN: idle candidate is logged as would-reap and left in place" || bad "DRY-RUN: wrong behaviour — got: $(cat "$IDLE_LOG")"

# A removal that FAILS is a failed cycle, not a quiet success: with a missing
# safe-clean every single reap fails, and a sweep that exits 0 there would
# look healthy while freeing nothing.
make_idle_fixture gate dead-idle-45m 45
_remove_scratchpad() { return 1; }
: > "$IDLE_LOG"
main; rc=$?
_remove_scratchpad() { rm -rf "$1"; }
{ [ -d "$(fx gate dead-idle-45m)" ] && [ "$rc" -ne 0 ] && grep -q "FAILED to reap" "$IDLE_LOG"; } && ok "REMOVAL FAILURE: dir kept, 'FAILED to reap' logged, cycle exits nonzero" || bad "REMOVAL FAILURE: rc=$rc log=$(cat "$IDLE_LOG")"

echo ""
echo "=== ga-hynohs: single-instance lock ==="
make_idle_fixture gate dead-idle-45m 45
rm -rf "$LOCK_DIR"; mkdir -p "$LOCK_DIR"; echo "$$" > "$LOCK_DIR/pid"        # a LIVE holder (this shell)
: > "$IDLE_LOG"
main; rc=$?
{ [ -d "$(fx gate dead-idle-45m)" ] && [ "$rc" -eq 0 ] && grep -q "holds" "$IDLE_LOG"; } && ok "LOCK: fresh lock held by a live pid → cycle skipped, logged, exit 0 (busy is not failure)" || bad "LOCK: live holder not respected (rc=$rc log=$(cat "$IDLE_LOG"))"
[ -d "$LOCK_DIR" ] && ok "LOCK: a skipped run does NOT remove the other run's lock" || bad "LOCK: skipped run deleted a lock it does not own"

rm -rf "$LOCK_DIR"; mkdir -p "$LOCK_DIR"                                          # holder pid not yet written (µs window)
main
[ -d "$(fx gate dead-idle-45m)" ] && ok "LOCK: lock dir with no pid yet → treated as LIVE, skipped (never steal a lock mid-birth)" || bad "LOCK: stole a lock whose holder had not written its pid"

sleep 0.1 & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null
rm -rf "$LOCK_DIR"; mkdir -p "$LOCK_DIR"; echo "$DEAD_PID" > "$LOCK_DIR/pid"   # a run killed by its caller's `timeout` leaves exactly this
main
[ -d "$(fx gate dead-idle-45m)" ] && bad "LOCK: lock left by a DEAD holder must be reclaimed, and the sweep must run" || ok "LOCK: dead holder's lock reclaimed → sweep ran and reaped"
[ ! -d "$LOCK_DIR" ] && ok "LOCK: lock released at the end of a run" || bad "LOCK: lock dir still present after a completed run"

# PID reuse: a killed run's pid can be handed to an unrelated long-lived
# process, which would make the lock look 'live' forever and silently switch
# the sweep off. A real run is bounded by its callers' timeouts (order 300s,
# guard 300s since ga-7jtyqjy), so a lock far older than that is stale whatever its pid says.
make_idle_fixture gate dead-idle-45m 45
rm -rf "$LOCK_DIR"; mkdir -p "$LOCK_DIR"; echo "$$" > "$LOCK_DIR/pid"
touch -t "$(age_ts 120)" "$LOCK_DIR"
main
[ -d "$(fx gate dead-idle-45m)" ] && bad "LOCK: a 2h-old lock whose pid is 'alive' (pid reuse) must be reclaimed" || ok "LOCK: 2h-old lock with a live-looking pid → reclaimed (PID reuse cannot disable the sweep)"

# Cannot create the lock at all = cannot know whether another run is going →
# inert, and loud.
make_idle_fixture gate dead-idle-45m 45
SAVED_LOCK_DIR="$LOCK_DIR"; LOCK_DIR="/nonexistent-root-$$/x/lock.d"
: > "$IDLE_LOG"
main; rc=$?
LOCK_DIR="$SAVED_LOCK_DIR"
{ [ -d "$(fx gate dead-idle-45m)" ] && [ "$rc" -ne 0 ] && grep -q "ABORT" "$IDLE_LOG"; } && ok "LOCK: cannot create the lock → nothing reaped, ABORT logged, nonzero exit" || bad "LOCK: uncreatable lock mishandled (rc=$rc log=$(cat "$IDLE_LOG"))"

echo ""
echo "=== ga-7jtyqjy: _fetch_live_keys — the gc call has its own deadline and says why it gave up ==="
# 08/11, load 26: `gc session list` took 58-90s. The reaper had no deadline of its own, so
# the disk-floor guard's `timeout 60` killed the whole run (no line from the reaper) in
# the very cycle it exists for. Now the call runs under timeout/gtimeout (150s by default)
# and an expired deadline is a logged ABORT with nothing reaped. No timeout binary = the
# old unbounded call (a missing tool must not switch the sweep off), and the log says
# "bound=none". Stand-ins: a fake gc (mode in FAKE_GC_MODE) and a fake timeout that
# records its argv.
eval "$REAL_LIVE_FN"
REAL_TMO_FN="$(declare -f _timeout_bin)"
GCDIR="$(mktemp -d /tmp/scratchpad-reaper-selftest-gc.XXXXXX)"; mkdir -p "$GCDIR/tmo"
cat > "$GCDIR/gc" <<'GCEOF'
#!/bin/bash
[ "$1 $2" = "session list" ] || exit 2
case "${FAKE_GC_MODE:-ok}" in
  ok)    echo '{"sessions":[{"session_key":"alive-a"},{"session_key":"alive-b"}]}' ;;
  quiet) echo '{"sessions":[]}' ;;
  nokey) echo '{"other":[]}' ;;
  empty) : ;;
  fail)  exit 3 ;;
  rc124) exit 124 ;;
  slow)  sleep "${FAKE_GC_SLEEP:-8}"; echo '{"sessions":[{"session_key":"alive-a"}]}' ;;
esac
GCEOF
cat > "$GCDIR/tmo/timeout" <<'TMOEOF'
#!/bin/bash
printf '%s\n' "$*" > "$FAKE_TMO_ARGV"
[ -z "${FAKE_TMO_RC:-}" ] || exit "$FAKE_TMO_RC"
while [ "${1#-}" != "$1" ]; do [ "$1" = -k ] && shift; shift; done
shift
exec "$@"
TMOEOF
chmod +x "$GCDIR/gc" "$GCDIR/tmo/timeout"
export FAKE_GC_MODE=ok FAKE_GC_SLEEP=8 FAKE_TMO_ARGV="$GCDIR/tmo.argv" FAKE_TMO_RC=""
KEYS="$GCDIR/keys"; SAVED_LOG="$LOG"; LOG="$GCDIR/reaper.log"; REAL_GC="$GC"; GC="$GCDIR/gc"; OLD_PATH="$PATH"; PATH="$GCDIR/tmo:$PATH"
GC_TIMEOUT_SECS=150
live() {  # live <gc-mode> → runs the real _fetch_live_keys; rc in $rc, keys in $KEYS, log in $LOG, argv of the fake timeout in $FAKE_TMO_ARGV
  : > "$KEYS"; : > "$LOG"; rm -f "$FAKE_TMO_ARGV"; FAKE_GC_MODE="$1"; _fetch_live_keys "$KEYS"; rc=$?
}
live ok
{ [ "$rc" -eq 0 ] && [ "$(sort "$KEYS" | tr '\n' ' ')" = "alive-a alive-b " ] && [ ! -s "$LOG" ]; } && ok "live_keys: gc answers → rc 0, both session keys written, nothing logged" || bad "live_keys ok: rc=$rc keys=$(cat "$KEYS") log=$(cat "$LOG")"
{ [ "${GC_LIST_BOUND:-<unset>}" = "150s" ] && case "${GC_LIST_ELAPSED:-<unset>}" in (''|*[!0-9]*) false ;; (*) true ;; esac; } && ok "live_keys: bound and elapsed are recorded for the cycle summary (bound=150s, elapsed a number)" || bad "live_keys: GC_LIST_BOUND='${GC_LIST_BOUND:-<unset>}' GC_LIST_ELAPSED='${GC_LIST_ELAPSED:-<unset>}'"
argv="$(cat "$FAKE_TMO_ARGV" 2>/dev/null)"
{ case "$argv" in ("-k 10 150 $GCDIR/gc session list --json") true ;; (*) false ;; esac; } && ok "live_keys: gc runs under 'timeout -k 10 150' (TERM at the deadline, KILL 10s later if gc ignores it)" || bad "live_keys: timeout argv was '$argv'"
live quiet
{ [ "$rc" -eq 0 ] && [ ! -s "$KEYS" ] && [ ! -s "$LOG" ]; } && ok "live_keys: a well-formed empty list is a QUIET TOWN, not an error (rc 0, no keys)" || bad "live_keys quiet: rc=$rc log=$(cat "$LOG")"
live nokey
{ [ "$rc" -ne 0 ] && grep -q "no .sessions key" "$LOG"; } && ok "live_keys: JSON without .sessions → ABORT (rc 1, logged)" || bad "live_keys nokey: rc=$rc log=$(cat "$LOG")"
live empty
{ [ "$rc" -ne 0 ] && grep -q "failed (rc=0) or returned empty" "$LOG"; } && ok "live_keys: gc printing nothing → ABORT (an empty answer is not a quiet town)" || bad "live_keys empty: rc=$rc log=$(cat "$LOG")"
live fail
{ [ "$rc" -ne 0 ] && grep -q "failed (rc=3)" "$LOG" && ! grep -q "did not answer" "$LOG"; } && ok "live_keys: gc exiting 3 → ABORT as a FAILURE, not as a timeout" || bad "live_keys fail: rc=$rc log=$(cat "$LOG")"
FAKE_TMO_RC=124; live ok; FAKE_TMO_RC=""
{ [ "$rc" -ne 0 ] && grep -q "did not answer within 150s" "$LOG" && ! grep -q "failed (rc=" "$LOG" && [ ! -s "$KEYS" ]; } && ok "live_keys: deadline expired (rc 124) → ABORT naming the 150s, not the generic failure; no key written" || bad "live_keys timeout: rc=$rc log=$(cat "$LOG")"
FAKE_TMO_RC=137; live ok; FAKE_TMO_RC=""
{ [ "$rc" -ne 0 ] && grep -q "did not answer within 150s" "$LOG"; } && ok "live_keys: rc 137 (timeout had to KILL gc) is the same timed-out ABORT" || bad "live_keys 137: rc=$rc log=$(cat "$LOG")"
for v in 7 abc 0 ""; do
  GC_TIMEOUT_SECS="$v"; live ok; want=150; [ "$v" = 7 ] && want=7
  case "$(cat "$FAKE_TMO_ARGV" 2>/dev/null)" in ("-k 10 $want "*) ok "live_keys: GC_TIMEOUT_SECS='$v' → deadline ${want}s (garbage/0/empty fall back to 150: 'timeout 0' would mean NO limit)" ;; (*) bad "live_keys: GC_TIMEOUT_SECS='$v' gave argv '$(cat "$FAKE_TMO_ARGV" 2>/dev/null)'" ;; esac
done
GC_TIMEOUT_SECS=150
_timeout_bin() { :; }
live ok
{ [ "$rc" -eq 0 ] && [ ! -e "$FAKE_TMO_ARGV" ] && [ "${GC_LIST_BOUND:-<unset>}" = "none" ]; } && ok "live_keys: no timeout/gtimeout binary → the call still runs (unbounded, as before) and the bound is reported as 'none'" || bad "live_keys no-timeout: rc=$rc bound='${GC_LIST_BOUND:-<unset>}' log=$(cat "$LOG")"
live rc124
{ [ "$rc" -ne 0 ] && grep -q "failed (rc=124)" "$LOG" && ! grep -q "did not answer" "$LOG"; } && ok "live_keys: with NO timeout binary an rc 124 is gc's own exit — a plain failure, nothing bounded it so it cannot mean 'timed out'" || bad "live_keys rc124 w/o timeout: rc=$rc log=$(cat "$LOG")"
eval "$REAL_TMO_FN"
PATH="$OLD_PATH"
if [ -n "$(_timeout_bin)" ]; then
  GC_TIMEOUT_SECS=1; FAKE_GC_SLEEP=8; t0=$(date +%s); live slow; t1=$(date +%s); GC_TIMEOUT_SECS=150
  { [ "$rc" -ne 0 ] && grep -q "did not answer within 1s" "$LOG" && [ $(( t1 - t0 )) -lt 6 ] && [ "${GC_LIST_ELAPSED:-0}" -ge 1 ]; } && ok "live_keys: a REAL timeout kills a gc that sleeps 8s after 1s ($(( t1 - t0 ))s, measured elapsed=${GC_LIST_ELAPSED}s) — the whole process group, no orphan holding the pipe" || bad "live_keys real timeout: rc=$rc took $(( t1 - t0 ))s elapsed='${GC_LIST_ELAPSED:-<unset>}' log=$(cat "$LOG")"
else
  echo "  SKIP: live_keys real-timeout row — no timeout/gtimeout on this host's PATH"
fi

# Whole cycle, real _fetch_live_keys: the deadline's ABORT reaps NOTHING, releases the lock, and the summary carries the numbers.
PATH="$GCDIR/tmo:$OLD_PATH"; LOG="$IDLE_LOG"; MIN_IDLE_MINUTES=30; FAKE_PROC_KEYS=""; FAKE_PROC_PROJS=""; FAKE_PROC_RC=0
make_idle_fixture gate dead-idle-45m 45
FAKE_TMO_RC=124; FAKE_GC_MODE=ok; : > "$IDLE_LOG"; rm -rf "$LOCK_DIR"
main; rc=$?; FAKE_TMO_RC=""
{ [ -d "$(fx gate dead-idle-45m)" ] && [ "$rc" -ne 0 ] && grep -q "did not answer within 150s" "$IDLE_LOG" && grep -q "skipping reap cycle entirely" "$IDLE_LOG" && [ ! -d "$LOCK_DIR" ]; } && ok "cycle: gc deadline expired → nothing reaped, ABORT logged, exit nonzero, lock released" || bad "cycle timeout: rc=$rc log=$(cat "$IDLE_LOG")"
FAKE_GC_MODE=quiet; : > "$IDLE_LOG"
main
{ [ ! -d "$(fx gate dead-idle-45m)" ] && grep -q "gc_list=[0-9]*s(bound=150s)" "$IDLE_LOG"; } && ok "cycle: gc answered in time → reaped, and the summary shows gc_list=Ns(bound=150s) (next pane: the log says how slow gc was)" || bad "cycle ok: log=$(cat "$IDLE_LOG")"
PATH="$OLD_PATH"; GC="$REAL_GC"; LOG="$SAVED_LOG"; unset FAKE_GC_MODE FAKE_GC_SLEEP FAKE_TMO_ARGV FAKE_TMO_RC
MIN_IDLE_MINUTES=30

echo ""
echo "=== ga-hynohs: _remove_scratchpad goes through the REAL safe-clean ==="
eval "$REAL_REMOVE_FN"
SAFE_CLEAN="$HERE/../packs/town-deltas/assets/scripts/safe-clean.py"
LOG="$IDLE_LOG"
# A fixture that safe-clean's allowlist recognises (/private/tmp/claude-*/*/*/**).
SC_ROOT="/private/tmp/claude-selftest-hynohs-$$"
mkdir -p "$SC_ROOT/proj/sid/scratchpad/tree"; : > "$SC_ROOT/proj/sid/scratchpad/tree/f"
_remove_scratchpad "$SC_ROOT/proj/sid/scratchpad"; rc=$?
{ [ "$rc" -eq 0 ] && [ ! -d "$SC_ROOT/proj/sid/scratchpad" ] && [ -d "$SC_ROOT/proj/sid" ]; } && ok "safe-clean: allowlisted scratchpad leaf removed, session dir left alone" || bad "safe-clean: allowlisted removal wrong (rc=$rc)"
# A path safe-clean does NOT recognise must be REFUSED, never force-deleted.
mkdir -p "$LOCK_PARENT/proj/sid/scratchpad"
_remove_scratchpad "$LOCK_PARENT/proj/sid/scratchpad"; rc=$?
{ [ "$rc" -ne 0 ] && [ -d "$LOCK_PARENT/proj/sid/scratchpad" ]; } && ok "safe-clean: a path outside its allowlist is refused (nonzero) and left intact — no rm -rf fallback" || bad "safe-clean: outside-allowlist path was deleted or reported ok (rc=$rc)"
# A missing safe-clean is a refusal, not a licence to fall back to rm -rf.
mkdir -p "$SC_ROOT/proj/sid2/scratchpad"
SAFE_CLEAN="/nonexistent/safe-clean-$$"
_remove_scratchpad "$SC_ROOT/proj/sid2/scratchpad"; rc=$?
{ [ "$rc" -ne 0 ] && [ -d "$SC_ROOT/proj/sid2/scratchpad" ]; } && ok "safe-clean: binary missing → fail-closed (nonzero, nothing deleted)" || bad "safe-clean: missing binary did not fail closed (rc=$rc)"
rm -rf "$SC_ROOT" "$FAKEBIN" "$IDLE_ROOT" "$IDLE_LOG" "$GCDIR"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
