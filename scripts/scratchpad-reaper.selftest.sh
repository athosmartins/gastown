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

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== scratchpad-reaper.selftest.sh ==="

# ── fixture: a live-keys file with two known session ids ────────────────────
KEYFILE="$(mktemp /tmp/scratchpad-reaper-selftest-keys.XXXXXX)"
printf 'alive-session-1\nalive-session-2\n' > "$KEYFILE"
trap 'rm -f "$KEYFILE"' EXIT

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
LARGE_KB=$(( 2 * 1024 * 1024 ))   # 2GB in KB, matching the default large_gb=2
BIG=$(( LARGE_KB + 1024 ))        # just over 2GB
SMALL=$(( LARGE_KB - 1024 ))      # just under 2GB
CRIT_OLD=$(( NOW - 2*3600 ))      # 2h old — past a 1h critical_min_age_hours
CRIT_FRESH=$(( NOW - 30*60 ))     # 30min old — under a 1h critical_min_age_hours

_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 ""              "$BIG"      2 && ok "size_escape: dead + old-enough + large-enough → escape reap"                                    || bad "dead+2h+big should size-escape"
_should_reap_size_escape "alive-session-1" "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 ""              "$BIG"      2 && bad "size_escape: live session must NEVER escape-reap regardless of size/pressure"                  || ok "size_escape: live session → never (liveness absolute)"
_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 "dead-session-9" "$BIG"      2 && bad "size_escape: CURRENT session id must never escape-reap"                                        || ok "size_escape: self id → never (self-protection absolute)"
_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_FRESH" "$NOW" 1 ""              "$BIG"      2 && bad "size_escape: dead+large but younger than critical_min_age_hours must NOT escape"               || ok "size_escape: too fresh for critical window → not yet"
_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 ""              "$SMALL"    2 && bad "size_escape: dead+old-enough but under large_gb must NOT escape"                               || ok "size_escape: too small → not eligible"
_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 ""              ""          2 && bad "size_escape: empty/unreadable size must NEVER authorize (fail toward keep)"                    || ok "size_escape: empty size_kb → false"
_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 ""              "abc"       2 && bad "size_escape: non-numeric size must NEVER authorize"                                            || ok "size_escape: non-numeric size_kb → false"
_should_reap_size_escape "dead-session-9"  "$KEYFILE" "$CRIT_OLD"   "$NOW" 1 ""              "$LARGE_KB" 2 && ok "size_escape: exactly at large_gb boundary → eligible (inclusive)"                                || bad "exactly 2GB should be inclusive"

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

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
