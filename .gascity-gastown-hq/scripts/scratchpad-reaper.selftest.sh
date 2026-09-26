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
rm -rf "$LOCK_DIR"; mkdir -p "$LOCK_DIR"; echo "$DEAD_PID" > "$LOCK_DIR/pid"   # a run killed by `timeout 60` leaves exactly this
main
[ -d "$(fx gate dead-idle-45m)" ] && bad "LOCK: lock left by a DEAD holder must be reclaimed, and the sweep must run" || ok "LOCK: dead holder's lock reclaimed → sweep ran and reaped"
[ ! -d "$LOCK_DIR" ] && ok "LOCK: lock released at the end of a run" || bad "LOCK: lock dir still present after a completed run"

# PID reuse: a killed run's pid can be handed to an unrelated long-lived
# process, which would make the lock look 'live' forever and silently switch
# the sweep off. A real run is bounded by its callers' timeouts (order 300s,
# guard 60s), so a lock far older than that is stale whatever its pid says.
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
rm -rf "$SC_ROOT" "$FAKEBIN" "$IDLE_ROOT" "$IDLE_LOG"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
