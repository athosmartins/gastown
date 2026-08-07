#!/bin/bash
# transcript-reaper.selftest.sh — unit tests for the PURE decision logic of
# transcript-reaper.sh (liveness lookup, mtime staleness, composed reap gate),
# PLUS an end-to-end integration test of main() against a disposable tmp root.
#
# Hermetic: sources the script as a LIBRARY (TRANSCRIPT_REAPER_LIB=1) so
# main() never auto-runs. The unit-test section never calls `gc session list`
# or touches any real file. The integration section DOES call the real
# main()/rm, but only against a throwaway TRANSCRIPT_REAPER_ROOT under /tmp
# that this file creates and removes — never real ~/.claude/projects data —
# with `_fetch_live_keys` stubbed so no real `gc`/jq call happens either.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/transcript-reaper.sh"

export TRANSCRIPT_REAPER_LIB=1
export TRANSCRIPT_REAPER_LOG="/tmp/transcript-reaper-selftest-$$.log"
# shellcheck disable=SC1090
. "$SCRIPT"

# Captured immediately after the ONLY source of this file, before any test
# below overrides TRANSCRIPT_REAL_DEFAULT_ROOT for hermetic fixture scenarios —
# this is the pristine production value (production-constant sanity check
# near the end of this file). Deliberately NOT re-sourced later: main()'s
# `trap ... RETURN` (harmless in production, where every real invocation is a
# fresh subprocess) leaks past a single function return in bash and fires
# again on the next sourced-script completion in the SAME shell, by which
# point the original invocation's local $keyfile is out of scope — re-sourcing
# after this file's main() scenarios run would hit that landmine under `set -u`.
PRODUCTION_REAL_DEFAULT_ROOT="$TRANSCRIPT_REAL_DEFAULT_ROOT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== transcript-reaper.selftest.sh ==="

# ── fixture: a live-keys file with two known session ids ────────────────────
KEYFILE="$(mktemp /tmp/transcript-reaper-selftest-keys.XXXXXX)"
printf 'alive-session-1\nalive-session-2\n' > "$KEYFILE"
trap 'rm -f "$KEYFILE"' EXIT

# ── _session_is_live: exact-line membership, not substring/prefix ───────────
_session_is_live "alive-session-1" "$KEYFILE" && ok "session_is_live: exact match in keyfile → true" || bad "should be live"
_session_is_live "dead-session-9" "$KEYFILE"   && bad "session_is_live: absent id should be false" || ok "session_is_live: absent id → false"
_session_is_live "alive-session"  "$KEYFILE"   && bad "session_is_live: PREFIX match must NOT count as live (substring false-positive)" || ok "session_is_live: prefix-only is not a match (-x exact line)"
_session_is_live "alive-session-1" "/nonexistent/keyfile-$$" && bad "session_is_live: missing keyfile should be false (fail toward dead, not live)" || ok "session_is_live: missing keyfile → false"

# ── _is_stale: hour-boundary math, non-numeric fail-closed (never stale) ────
NOW=1000000
_is_stale $(( NOW - 73*3600 )) "$NOW" 72 && ok "is_stale: 73h old, min 72h → stale" || bad "73h should be stale at min=72h"
_is_stale $(( NOW - 72*3600 )) "$NOW" 72 && ok "is_stale: exactly 72h old → stale (boundary inclusive)" || bad "72h boundary should be inclusive"
_is_stale $(( NOW - 71*3600 )) "$NOW" 72 && bad "is_stale: 71h old should NOT be stale yet" || ok "is_stale: 71h old → not stale"
_is_stale ""    "$NOW" 72 && bad "is_stale: empty mtime (stat failed) must NOT be stale (never authorize deletion on unreadable mtime)" || ok "is_stale: empty mtime → false (fail toward keep)"
_is_stale "abc" "$NOW" 72 && bad "is_stale: non-numeric mtime should be false" || ok "is_stale: non-numeric mtime → false"

# ── _should_reap: composed gate — self-protection beats everything, then
#    liveness, then staleness ────────────────────────────────────────────────
OLD=$(( NOW - 96*3600 ))
RECENT=$(( NOW - 1*3600 ))
_should_reap "dead-session-9"  "$KEYFILE" "$OLD"    "$NOW" 72 ""               && ok "should_reap: dead + stale + no self set → reap"                            || bad "dead+stale should reap"
_should_reap "alive-session-1" "$KEYFILE" "$OLD"    "$NOW" 72 ""               && bad "should_reap: live session must NEVER reap regardless of age"             || ok "should_reap: live session → never reap"
_should_reap "dead-session-9"  "$KEYFILE" "$RECENT" "$NOW" 72 ""               && bad "should_reap: dead but too recent must NOT reap"                          || ok "should_reap: dead-but-fresh → not yet"
_should_reap "dead-session-9"  "$KEYFILE" "$OLD"    "$NOW" 72 "dead-session-9" && bad "should_reap: CURRENT session id must NEVER reap even if it otherwise qualifies" || ok "should_reap: self-protection overrides dead+stale"
_should_reap "alive-session-1" "$KEYFILE" "$OLD"    "$NOW" 72 "dead-session-9" && bad "should_reap: unrelated self id must not change a live session's outcome" || ok "should_reap: self set but different id → still protected by liveness"

# ── _prod_sentinel_active: PRODUCTION SENTINEL (ga-h565g/ga-lfj05) — a
#    resolved root equal to the real default with no explicit prod opt-in
#    must block deletion. Pure/no filesystem access: these pass plain
#    strings; the actual production constant is exercised separately below
#    via main() ────────────────────────────────────────────────────────────
_prod_sentinel_active "/Users/athos/.claude/projects" "/Users/athos/.claude/projects" ""  && ok "prod_sentinel_active: root==real default, no PROD → active (blocks)"        || bad "root==default+no PROD should be active"
_prod_sentinel_active "/Users/athos/.claude/projects" "/Users/athos/.claude/projects" "0" && ok "prod_sentinel_active: root==real default, PROD=0 → active (blocks)"         || bad "root==default+PROD=0 should be active"
_prod_sentinel_active "/Users/athos/.claude/projects" "/Users/athos/.claude/projects" "1" && bad "prod_sentinel_active: PROD=1 must disable the sentinel even when root==default" || ok "prod_sentinel_active: root==default+PROD=1 → not active (allowed)"
_prod_sentinel_active "/tmp/some-fixture-root"        "/Users/athos/.claude/projects" ""  && bad "prod_sentinel_active: a DIFFERENT (fixture) root must never trip the sentinel"  || ok "prod_sentinel_active: fixture root != default → not active"
_prod_sentinel_active "/tmp/some-fixture-root"        "/Users/athos/.claude/projects" "1" && bad "prod_sentinel_active: fixture root + PROD=1 must still be inactive"        || ok "prod_sentinel_active: fixture root + PROD=1 → not active"

echo ""
echo "=== _workdir_to_project_slug: Claude Code's '/' and '.' -> '-' convention ==="
[ "$(_workdir_to_project_slug "/Users/athos/gt/.gascity-gastown-hq")" = "-Users-athos-gt--gascity-gastown-hq" ] \
  && ok "workdir_to_project_slug: matches this machine's live ~/.claude/projects/ naming" \
  || bad "workdir_to_project_slug: slug mismatch vs. verified live directory name"
[ "$(_workdir_to_project_slug "/a/b")" = "-a-b" ] \
  && ok "workdir_to_project_slug: simple path, no dots" \
  || bad "workdir_to_project_slug: simple path mismatch"

echo ""
echo "=== _shield_unresolved_session: null-session_key protection by work_dir ==="
SHIELD_ROOT="$(mktemp -d /tmp/transcript-reaper-selftest-shield.XXXXXX)"
mkdir -p "$SHIELD_ROOT/-work-dir-slug"
: > "$SHIELD_ROOT/-work-dir-slug/some-session-a.jsonl"
: > "$SHIELD_ROOT/-work-dir-slug/some-session-b.jsonl"
SHIELD_OUT="$(mktemp /tmp/transcript-reaper-selftest-shieldout.XXXXXX)"

_shield_unresolved_session "$SHIELD_OUT" "/work/dir/slug" "$SHIELD_ROOT"
grep -qxF "some-session-a" "$SHIELD_OUT" && grep -qxF "some-session-b" "$SHIELD_OUT" \
  && ok "shield_unresolved_session: every .jsonl under the mapped project dir is shielded" \
  || bad "shield_unresolved_session: shielded ids missing from out file"

: > "$SHIELD_OUT"
_shield_unresolved_session "$SHIELD_OUT" "" "$SHIELD_ROOT"
[ ! -s "$SHIELD_OUT" ] && ok "shield_unresolved_session: empty work_dir → no-op (nothing to shield)" || bad "shield_unresolved_session: empty work_dir should no-op"

: > "$SHIELD_OUT"
_shield_unresolved_session "$SHIELD_OUT" "/no/such/mapped/dir" "$SHIELD_ROOT"
[ ! -s "$SHIELD_OUT" ] && ok "shield_unresolved_session: project dir doesn't exist → no-op" || bad "shield_unresolved_session: nonexistent project dir should no-op"

rm -rf "$SHIELD_ROOT"
rm -f "$SHIELD_OUT"

echo ""
echo "=== _fetch_live_keys: real jq pipeline against a stubbed 'gc session list --json' ==="
# GATE-FLAGGED BUG (ga-t1ub9, fix-attempt 1 FAIL): the original _fetch_live_keys
# used `.session_key // empty`, silently dropping any session with a null/absent
# session_key from the live set — giving it ZERO reap protection. This section
# exercises the REAL _fetch_live_keys (not stubbed, unlike the main() test
# below) against a fake `gc` binary, so the actual jq parsing this bug lived in
# is under test, not just the pure helper functions.
FLK_ROOT="$(mktemp -d /tmp/transcript-reaper-selftest-flk.XXXXXX)"
mkdir -p "$FLK_ROOT/-null-with-dir"
: > "$FLK_ROOT/-null-with-dir/shielded-1.jsonl"
: > "$FLK_ROOT/-null-with-dir/shielded-2.jsonl"

FAKE_GC_DIR="$(mktemp -d /tmp/transcript-reaper-selftest-gcbin.XXXXXX)"
cat > "$FAKE_GC_DIR/fake-gc" <<'FAKEGC'
#!/bin/bash
cat <<JSON
{"sessions":[
  {"id":"ga-live1","session_name":"live-one","state":"active","session_key":"real-uuid-live-one","work_dir":"/irrelevant"},
  {"id":"ga-nullwd","session_name":"null-with-dir","state":"asleep","session_key":null,"work_dir":"/null/with/dir"},
  {"id":"ga-nullnodir","session_name":"null-no-workdir","state":"active","session_key":""}
]}
JSON
FAKEGC
chmod +x "$FAKE_GC_DIR/fake-gc"

FLK_OUT="$(mktemp /tmp/transcript-reaper-selftest-flkout.XXXXXX)"
# Internal var names, not their TRANSCRIPT_REAPER_*/GC_BIN env counterparts —
# same footgun as TRANSCRIPT_ROOT/ENABLED/DRY_RUN below (env vars resolve once
# at source time; reassigning the env name here would silently no-op).
TRANSCRIPT_ROOT="$FLK_ROOT"
GC="$FAKE_GC_DIR/fake-gc"
: > "$TRANSCRIPT_REAPER_LOG"

_fetch_live_keys "$FLK_OUT"
FLK_RC=$?

[ "$FLK_RC" -eq 0 ] && ok "fetch_live_keys: well-formed sessions payload → success (rc=0)" || bad "fetch_live_keys: unexpected nonzero rc=$FLK_RC"
grep -qxF "real-uuid-live-one" "$FLK_OUT" && ok "fetch_live_keys: real session_key passes through unchanged" || bad "fetch_live_keys: real session_key missing from out file"
grep -qxF "shielded-1" "$FLK_OUT" && grep -qxF "shielded-2" "$FLK_OUT" \
  && ok "fetch_live_keys: null-session_key entry's work_dir shields its project dir's transcripts" \
  || bad "fetch_live_keys: null-key work_dir shielding did not protect its project dir's files — THE GATE-FLAGGED BUG"
grep -q "null-with-dir" "$TRANSCRIPT_REAPER_LOG" && grep -q "shielding its project dir" "$TRANSCRIPT_REAPER_LOG" \
  && ok "fetch_live_keys: null-session_key gap is logged (never silently dropped)" \
  || bad "fetch_live_keys: null-session_key gap must be logged, not silently dropped"
grep -q "null-no-workdir" "$TRANSCRIPT_REAPER_LOG" && grep -q "cannot shield" "$TRANSCRIPT_REAPER_LOG" \
  && ok "fetch_live_keys: null-session_key WITHOUT work_dir logs an explicit cannot-shield warning" \
  || bad "fetch_live_keys: missing cannot-shield warning when work_dir is also absent"

rm -rf "$FLK_ROOT" "$FAKE_GC_DIR"
rm -f "$FLK_OUT"

echo ""
echo "=== _fetch_live_keys: '.sessions' null/missing must ABORT, not collapse to empty ==="
# GATE-FLAGGED BUG (ga-t1ub9, fix-attempt 2 FAIL, gate_run=ga-wisp-kq50t3g):
# has("sessions") returns true even when the value is null — {"sessions": null}
# passed the old guard, then '.sessions[]' errored (jq exit 5) iterating over
# null, got swallowed by 2>/dev/null, and _fetch_live_keys returned 0 with an
# EMPTY keyfile: every session would read as dead. Fixed via
# '(.sessions | type) == "array"', which rejects null and non-array alike.
NULLSESS_GC_DIR="$(mktemp -d /tmp/transcript-reaper-selftest-nullgc.XXXXXX)"
cat > "$NULLSESS_GC_DIR/fake-gc" <<'FAKEGC'
#!/bin/bash
echo '{"sessions": null}'
FAKEGC
chmod +x "$NULLSESS_GC_DIR/fake-gc"

NULLSESS_OUT="$(mktemp /tmp/transcript-reaper-selftest-nullout.XXXXXX)"
GC="$NULLSESS_GC_DIR/fake-gc"
: > "$TRANSCRIPT_REAPER_LOG"

_fetch_live_keys "$NULLSESS_OUT"
NULLSESS_RC=$?

[ "$NULLSESS_RC" -ne 0 ] && ok "fetch_live_keys: '.sessions: null' → nonzero rc (abort, not silent-empty) — THE GATE-FLAGGED BUG" || bad "fetch_live_keys: '.sessions: null' returned rc=0 — would silently reap every session"
grep -q "ABORT" "$TRANSCRIPT_REAPER_LOG" && ok "fetch_live_keys: '.sessions: null' logs an ABORT" || bad "fetch_live_keys: '.sessions: null' abort not logged"

rm -rf "$NULLSESS_GC_DIR"
rm -f "$NULLSESS_OUT"

echo ""
echo "=== _fetch_live_keys: '.sessions' key entirely absent must also ABORT ==="
NOSESS_GC_DIR="$(mktemp -d /tmp/transcript-reaper-selftest-nogc.XXXXXX)"
cat > "$NOSESS_GC_DIR/fake-gc" <<'FAKEGC'
#!/bin/bash
echo '{}'
FAKEGC
chmod +x "$NOSESS_GC_DIR/fake-gc"

NOSESS_OUT="$(mktemp /tmp/transcript-reaper-selftest-noout.XXXXXX)"
GC="$NOSESS_GC_DIR/fake-gc"
: > "$TRANSCRIPT_REAPER_LOG"

_fetch_live_keys "$NOSESS_OUT"
NOSESS_RC=$?

[ "$NOSESS_RC" -ne 0 ] && ok "fetch_live_keys: missing '.sessions' key → nonzero rc (abort)" || bad "fetch_live_keys: missing '.sessions' key returned rc=0"

rm -rf "$NOSESS_GC_DIR"
rm -f "$NOSESS_OUT"

echo ""
echo "=== main(): _fetch_live_keys failure must abort the WHOLE cycle — zero deletions ==="
# Structural regression guard for the same gate finding, at main()'s level:
# even if a future change alters how _fetch_live_keys decides to fail, main()
# must still refuse to reap ANYTHING when it can't establish a trustworthy
# live-session set — never fall back to "treat unknown as dead".
ABORT_ROOT="$(mktemp -d /tmp/transcript-reaper-selftest-abortroot.XXXXXX)"
mkdir -p "$ABORT_ROOT/proj"
: > "$ABORT_ROOT/proj/clearly-dead-and-stale.jsonl"
OLD_TS_ABORT="$(date -v-10d +%Y%m%d%H%M.%S)"
touch -t "$OLD_TS_ABORT" "$ABORT_ROOT/proj/clearly-dead-and-stale.jsonl"

_fetch_live_keys() { return 1; }

TRANSCRIPT_ROOT="$ABORT_ROOT"
ENABLED=1
DRY_RUN=0
MIN_AGE_HOURS=72
SELF_SESSION_ID=""

main
MAIN_ABORT_RC=$?

[ "$MAIN_ABORT_RC" -ne 0 ] && ok "main(): propagates _fetch_live_keys failure as nonzero rc" || bad "main(): swallowed _fetch_live_keys failure, returned 0"
[ -f "$ABORT_ROOT/proj/clearly-dead-and-stale.jsonl" ] \
  && ok "main(): liveness-fetch failure reaps NOTHING, even an obviously dead+stale file" \
  || bad "main(): reaped a file despite being unable to establish liveness — THE EXACT GATE-FLAGGED RISK"

rm -rf "$ABORT_ROOT"

echo ""
echo "=== main(): end-to-end integration against a disposable tmp root ==="
# Fixture layout under a throwaway TRANSCRIPT_ROOT (never real ~/.claude/projects):
#   proj/live-sess.jsonl        — LIVE session, OLD mtime  → must survive (liveness beats age)
#   proj/dead-old.jsonl         — DEAD session, OLD mtime, HAS sibling dir → both removed
#   proj/dead-old/tool-results/x.txt   (the sibling dir contents)
#   proj/dead-fresh.jsonl       — DEAD session, FRESH mtime → must survive (grace period)
#   proj/dead-old-nodir.jsonl   — DEAD session, OLD mtime, NO sibling dir → jsonl removed, no error
#   proj/self-sess.jsonl        — DEAD-per-liveness-list but IS SELF → must survive
TMPROOT="$(mktemp -d /tmp/transcript-reaper-selftest-root.XXXXXX)"
mkdir -p "$TMPROOT/proj/dead-old/tool-results"
echo x > "$TMPROOT/proj/dead-old/tool-results/x.txt"
: > "$TMPROOT/proj/live-sess.jsonl"
: > "$TMPROOT/proj/dead-old.jsonl"
: > "$TMPROOT/proj/dead-fresh.jsonl"
: > "$TMPROOT/proj/dead-old-nodir.jsonl"
: > "$TMPROOT/proj/self-sess.jsonl"

OLD_TS="$(date -v-5d +%Y%m%d%H%M.%S)"
touch -t "$OLD_TS" "$TMPROOT/proj/live-sess.jsonl"
touch -t "$OLD_TS" "$TMPROOT/proj/dead-old.jsonl"
touch -t "$OLD_TS" "$TMPROOT/proj/dead-old/tool-results/x.txt"
touch -t "$OLD_TS" "$TMPROOT/proj/dead-old-nodir.jsonl"
touch -t "$OLD_TS" "$TMPROOT/proj/self-sess.jsonl"
# dead-fresh.jsonl deliberately left at "just created" (now) — within the grace window

# Stub liveness: only "live-sess" is in the live set (no real `gc`/jq call).
_fetch_live_keys() { printf 'live-sess\n' > "$1"; }

# NOTE: these must be the script's INTERNAL variable names (TRANSCRIPT_ROOT,
# ENABLED, DRY_RUN), not their TRANSCRIPT_REAPER_* env-var counterparts — the
# env vars are only read ONCE at source time (already resolved to defaults by
# now); reassigning the env-var names here would silently no-op and leave
# main() scanning the REAL ~/.claude/projects instead of this fixture.
TRANSCRIPT_ROOT="$TMPROOT"
ENABLED=1
DRY_RUN=0
MIN_AGE_HOURS=72
SELF_SESSION_ID="self-sess"

main

[ -f "$TMPROOT/proj/live-sess.jsonl" ] && ok "main(): LIVE session's old transcript survives (liveness beats age)" || bad "main(): live-sess.jsonl was wrongly reaped"
[ -f "$TMPROOT/proj/dead-old.jsonl" ]  && bad "main(): dead+stale transcript should have been reaped" || ok "main(): dead+stale transcript reaped"
[ -d "$TMPROOT/proj/dead-old" ]       && bad "main(): dead+stale transcript's sibling dir should have been reaped too" || ok "main(): dead+stale transcript's sibling dir reaped alongside it"
[ -f "$TMPROOT/proj/dead-fresh.jsonl" ] && ok "main(): dead-but-FRESH transcript survives (grace period)" || bad "main(): dead-fresh.jsonl was wrongly reaped before its grace period elapsed"
[ -f "$TMPROOT/proj/dead-old-nodir.jsonl" ] && bad "main(): dead+stale transcript with no sibling dir should still be reaped" || ok "main(): dead+stale transcript with no sibling dir reaped cleanly (no error from missing dir)"
[ -f "$TMPROOT/proj/self-sess.jsonl" ] && ok "main(): CALLER's own session transcript survives even though absent from the (stubbed) live list" || bad "main(): self-sess.jsonl was wrongly reaped — self-protection failed"

rm -rf "$TMPROOT"

echo ""
echo "=== main(): production sentinel end-to-end (ga-h565g/ga-lfj05) ==="
# Hermetic trick: reassign TRANSCRIPT_REAL_DEFAULT_ROOT (a plain global, not
# readonly) to a disposable tmp path so these scenarios exercise the REAL
# main() sentinel-forcing logic end-to-end without ever pointing at the
# actual ~/.claude/projects — the sentinel compares TRANSCRIPT_ROOT against
# WHATEVER TRANSCRIPT_REAL_DEFAULT_ROOT currently holds, so this is a
# faithful exercise of the same code path production uses, just pointed at a
# throwaway fixture. A separate check further below (outside this override)
# confirms the constant's REAL value is the actual expected production path.
# This is the exact incident class ga-lfj05 exists to close: a harness bug
# that leaves the resolved root at its real default (2026-07-26: 185 real
# transcripts deleted this way) must never be able to delete real data on
# its own again.
_fetch_live_keys() { : > "$1"; }  # nobody "live" — every candidate is dead
OLD_TS="$(date -v-5d +%Y%m%d%H%M.%S)"
SENTINEL_ROOT="$(mktemp -d /tmp/transcript-reaper-selftest-sentinel.XXXXXX)"

make_sentinel_fixture() {
  rm -rf "$SENTINEL_ROOT"
  mkdir -p "$SENTINEL_ROOT/proj"
  : > "$SENTINEL_ROOT/proj/dead-old.jsonl"
  touch -t "$OLD_TS" "$SENTINEL_ROOT/proj/dead-old.jsonl"
}

TRANSCRIPT_REAL_DEFAULT_ROOT="$SENTINEL_ROOT"   # pretend this tmp dir IS "the real default"
TRANSCRIPT_ROOT="$SENTINEL_ROOT"                # and the resolved root equals it exactly
# shellcheck disable=SC2034  # read by main() in the sourced script
ENABLED=1
# shellcheck disable=SC2034  # read by main()/_should_reap in the sourced script
MIN_AGE_HOURS=72
# shellcheck disable=SC2034  # read by main()/_should_reap in the sourced script
SELF_SESSION_ID=""

# Scenario: real-default root, no PROD opt-in → must NOT delete.
make_sentinel_fixture
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
# shellcheck disable=SC2034  # read by main() in the sourced script
PROD=0
main
[ -f "$SENTINEL_ROOT/proj/dead-old.jsonl" ] && ok "main(): root==real-default + no PROD opt-in → candidate survives (sentinel blocks deletion)" || bad "main(): sentinel FAILED to block — real-default root deleted data with no PROD opt-in"

# Scenario: same root, PROD=1 → normal reap resumes (real launchd-path behavior).
make_sentinel_fixture
DRY_RUN=0; PROD=1
main
[ -f "$SENTINEL_ROOT/proj/dead-old.jsonl" ] && bad "main(): PROD=1 should allow the real launchd path to reap normally" || ok "main(): root==real-default + PROD=1 → reaps normally (opt-in respected)"

rm -rf "$SENTINEL_ROOT"

# Non-regression: a FIXTURE root (never equal to the real default) must reap
# normally with no PROD opt-in at all — the sentinel must never fire for
# ordinary test/tmp-fixture roots, only for the literal real-default value.
FIXTURE_ROOT="$(mktemp -d /tmp/transcript-reaper-selftest-fixture.XXXXXX)"
mkdir -p "$FIXTURE_ROOT/proj"
: > "$FIXTURE_ROOT/proj/dead-old.jsonl"
touch -t "$OLD_TS" "$FIXTURE_ROOT/proj/dead-old.jsonl"
TRANSCRIPT_REAL_DEFAULT_ROOT="/Users/athos/.claude/projects-nonexistent-marker-$$"  # deliberately NOT $FIXTURE_ROOT
# shellcheck disable=SC2034  # read by main() in the sourced script
TRANSCRIPT_ROOT="$FIXTURE_ROOT"
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
# shellcheck disable=SC2034  # read by main() in the sourced script
PROD=0
main
[ -f "$FIXTURE_ROOT/proj/dead-old.jsonl" ] && bad "main(): fixture root (!= real default) must reap normally, sentinel must not fire" || ok "main(): fixture root (!= real default) → sentinel inactive, reaps normally (no regression)"
rm -rf "$FIXTURE_ROOT"

echo ""
echo "=== production constant sanity (ga-h565g/ga-lfj05) ==="
# Uses the value captured immediately after this file's ONLY source (top of
# file), before any scenario above overrode TRANSCRIPT_REAL_DEFAULT_ROOT for
# hermetic testing — confirms the constant actually used in production is
# exactly the expected real default (catches drift between the
# default-resolution line and the sentinel-comparison constant).
[ "$PRODUCTION_REAL_DEFAULT_ROOT" = "/Users/athos/.claude/projects" ] && ok "production constant: TRANSCRIPT_REAL_DEFAULT_ROOT matches the expected real default path" || bad "production constant drifted: got '$PRODUCTION_REAL_DEFAULT_ROOT'"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
