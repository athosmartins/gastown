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

echo ""
echo "=== MIN_AGE_HOURS default (ga-5ppqo: 72h only ever reached 281MB/1.6G — 82% of volume was newer) ==="
# Fresh subshell, no TRANSCRIPT_REAPER_MIN_AGE_HOURS override — exercises the
# actual `${TRANSCRIPT_REAPER_MIN_AGE_HOURS:-24}` fallback in the script file
# itself, not a copy of the number. The main sourcing at the top of this file
# doesn't re-test this: env-var defaults resolve once at source time, so a
# change to the fallback constant would otherwise go unnoticed here.
DEFAULT_MIN_AGE="$(env -u TRANSCRIPT_REAPER_MIN_AGE_HOURS SCRIPT_PATH="$SCRIPT" bash -c 'TRANSCRIPT_REAPER_LIB=1 . "$SCRIPT_PATH"; echo "$MIN_AGE_HOURS"' 2>/dev/null)"
[ "$DEFAULT_MIN_AGE" = "24" ] \
  && ok "MIN_AGE_HOURS default: fresh source, no env override → 24 (was 72; ga-5ppqo measured 82% of volume newer than 72h)" \
  || bad "MIN_AGE_HOURS default: expected 24, got '$DEFAULT_MIN_AGE'"

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
echo "=== ga-esorlre.1: the conversation the Athos is USING is not the bead's session_key (real fetchers + real main) ==="
# BUG (ga-esorlre.1; the epic's 12/11 adversarial review, read on the mini): the Athos switches conversations inside a crew
# (/resume), so the transcript he is using is the `sessionId` of ~/.claude/sessions/<pid>.json, NOT the
# `session_key` of the crew's session bead (thies: live 53bf2758, bead d27b72b2; digo: live d150ee9b,
# bead 5eb94e99). The reaper only knew session_keys, so a live conversation with no write for 24h was
# deleted. Every scenario below runs the REAL main() with the REAL _fetch_live_keys,
# _fetch_live_conversations and _fetch_captured_ids against a fake gc, a fake bd and a fake sessions
# dir. One transcript per protection rule, all 5 days old: a rule that stops protecting costs exactly
# its own file, so only the scenario that owns that rule fails.
CV_ROOT="$(mktemp -d /tmp/transcript-reaper-selftest-cvroot.XXXXXX)"
CV_SESS="$(mktemp -d /tmp/transcript-reaper-selftest-cvsess.XXXXXX)"
CV_BIN="$(mktemp -d /tmp/transcript-reaper-selftest-cvbin.XXXXXX)"
CV_OLD_TS="$(date -v-5d +%Y%m%d%H%M.%S)"
CV_SESS_USE=""
CV_GC_USE=""
CV_NULLGLOB=0
CV_RC=0

cat > "$CV_BIN/fake-gc" <<'FAKEGC'
#!/bin/bash
echo '{"sessions":[{"id":"ga-crew1","session_name":"thies-crew","state":"active","session_key":"bead-key-thies","work_dir":"/w/thies"}]}'
FAKEGC
cat > "$CV_BIN/fake-bd" <<FAKEBD
#!/bin/bash
printf '%s\n' "\$@" > "$CV_BIN/bd.args"
[ -f "$CV_BIN/bd.out" ] && cat "$CV_BIN/bd.out"
exit "\$(cat "$CV_BIN/bd.rc" 2>/dev/null || echo 0)"
FAKEBD
cat > "$CV_BIN/fake-gc-empty" <<'FAKEGC'
#!/bin/bash
echo '{"sessions":[]}'
FAKEGC
cat > "$CV_BIN/fake-ps" <<'FAKEPS'
#!/bin/bash
echo "ps: simulated failure" >&2
exit 3
FAKEPS
# rc 1 like "no such process", but WITH a complaint: that is ps failing, not a pid that is gone
cat > "$CV_BIN/fake-ps1" <<'FAKEPS'
#!/bin/bash
echo "ps: Invalid process id" >&2
exit 1
FAKEPS
# dies without a word and with an rc other than 1: not "no such process" either
cat > "$CV_BIN/fake-ps2s" <<'FAKEPS'
#!/bin/bash
exit 2
FAKEPS
# a jq that crashes on the metadata-extraction program only (everything else runs the real jq)
mkdir -p "$CV_BIN/jq-shim"
cat > "$CV_BIN/jq-shim/jq" <<FAKEJQ
#!/bin/bash
case "\$*" in *to_entries*) echo "jq: simulated crash" >&2; exit 5 ;; esac
exec "$(command -v jq)" "\$@"
FAKEJQ
chmod +x "$CV_BIN/fake-gc" "$CV_BIN/fake-gc-empty" "$CV_BIN/fake-bd" "$CV_BIN/fake-ps" "$CV_BIN/fake-ps1" "$CV_BIN/fake-ps2s" "$CV_BIN/jq-shim/jq"
: > "$CV_BIN/not-a-dir"; chmod 755 "$CV_BIN/not-a-dir"    # executable on purpose: only "is it a directory?" can reject it

cv_t()  { : > "$CV_ROOT/proj/$1.jsonl"; touch -t "$CV_OLD_TS" "$CV_ROOT/proj/$1.jsonl"; }   # an OLD transcript
cv_alive() { [ -f "$CV_ROOT/proj/$1.jsonl" ]; }                                             # still there?
cv_bd() { printf '%s' "$1" > "$CV_BIN/bd.out"; printf '%s' "${2:-0}" > "$CV_BIN/bd.rc"; }   # what the fake bd answers
# a ~/.claude/sessions/<pid>.json like the real one (keys measured on the node: pid, sessionId, cwd, procStart ...)
cv_sf() { printf '{"pid":%s,"sessionId":"%s","cwd":"/w/thies","procStart":"x","kind":"interactive","status":"idle"}\n' "$1" "$2" > "$CV_SESS/$1.json"; }
cv_dead_pid() { local p; ( exit 0 ) & p=$!; wait "$p" 2>/dev/null; echo "$p"; }               # a pid that has exited and been reaped
cv_reset() {
  rm -f "$CV_ROOT"/proj/*.jsonl "$CV_SESS"/* "$CV_BIN/bd.args"
  mkdir -p "$CV_ROOT/proj"
  cv_bd '[{"id":"ga-crew1","issue_type":"session","status":"open","metadata":{"session_key":"bead-key-thies","state":"awake"}}]'
  CV_SESS_USE=""; CV_GC_USE=""; CV_NULLGLOB=0; PS=ps
  : > "$TRANSCRIPT_REAPER_LOG"
}
# The real main() in a SUBSHELL: its `trap 'rm -f "$keyfile"' RETURN` (see the note at the top of this
# file) would otherwise fire again when THIS function returns, with main's local $keyfile out of scope.
cv_run() {
  (
    TRANSCRIPT_ROOT="$CV_ROOT"; GC="${CV_GC_USE:-$CV_BIN/fake-gc}"; BD="$CV_BIN/fake-bd"; SESSIONS_DIR="${CV_SESS_USE:-$CV_SESS}"
    ENABLED=1; DRY_RUN=0; MIN_AGE_HOURS=24; SELF_SESSION_ID=""; PROD=0
    [ "$CV_NULLGLOB" = "1" ] && shopt -s nullglob      # production runs the fetchers with nullglob OFF (main() sets it later): default is off
    main </dev/null                                    # (a grep that mistakes an id for an option must fail this run, not wait on a terminal)
  )
  CV_RC=$?
}
CV_DEAD="$(cv_dead_pid)"
ps -p "$CV_DEAD" >/dev/null 2>&1 && bad "fixture: the 'dead' pid $CV_DEAD is alive — pid reused, rerun" || ok "fixture: a pid that really exited ($CV_DEAD) for the dead-process scenarios"

# 1. THE BUG: a live process whose sessionId is not any session's session_key
cv_reset
cv_sf "$$" "conv-in-use-by-athos"
cv_t "conv-in-use-by-athos"; cv_t "bead-key-thies"; cv_t "nobody-owns-this"
cv_run
[ "$CV_RC" -eq 0 ] && ok "conv/live pid: cycle completes (rc=0)" || bad "conv/live pid: cycle rc=$CV_RC"
cv_alive "conv-in-use-by-athos" \
  && ok "conv/live pid: the sessionId of a LIVE process survives 5 days without a write although it is no session_key — THE BUG" \
  || bad "conv/live pid: live conversation reaped — the Athos's conversation is deleted (only session_keys were protected)"
cv_alive "bead-key-thies" && ok "conv/live pid: the listed session_key still survives (unchanged)" || bad "conv/live pid: session_key transcript reaped"
cv_alive "nobody-owns-this" && bad "conv/live pid: a transcript nobody owns must still be reaped (the run really reaped)" || ok "conv/live pid: a transcript nobody owns is still reaped"
grep -q "protecting conversation conv-in-use-by-athos" "$TRANSCRIPT_REAPER_LOG" \
  && ok "conv/live pid: the find is logged (audit trail: protected, and why)" \
  || bad "conv/live pid: no 'protecting conversation' line for the id that is not a session_key"
grep -q "protecting conversation conv-in-use-by-athos: pid $$ .* is alive and the id is not the session_key" "$TRANSCRIPT_REAPER_LOG" \
  && ok "conv/live pid: the audit line says the pid is alive, and names it" \
  || bad "conv/live pid: audit line does not say 'is alive' for a verified-alive pid: $(grep 'protecting conversation' "$TRANSCRIPT_REAPER_LOG" | tr '\n' ' ')"
grep -q "live-conversation scan: .* files=1 protected=1 gone=0 ignored_unreadable_dead=0" "$TRANSCRIPT_REAPER_LOG" \
  && ok "conv/live pid: the scan summary counts what it saw (files=1 protected=1 gone=0)" \
  || bad "conv/live pid: scan summary missing or wrong: $(grep 'live-conversation scan:' "$TRANSCRIPT_REAPER_LOG" | tr '\n' ' ')"

# 1b. the sessionId IS a listed session_key: protected as before, and not reported as a find
cv_reset
cv_sf "$$" "bead-key-thies"
cv_t "bead-key-thies"
cv_run
cv_alive "bead-key-thies" && ok "conv/same id: a sessionId equal to a session_key survives" || bad "conv/same id: reaped"
grep -q "protecting conversation bead-key-thies" "$TRANSCRIPT_REAPER_LOG" \
  && bad "conv/same id: an id that is already a session_key must not be logged as a new find" \
  || ok "conv/same id: an id that is already a session_key is not logged as a find"

# 2. a session file whose process is gone protects nothing (a leftover must not pin a transcript forever)
cv_reset
cv_sf "$CV_DEAD" "conv-of-dead-process"
cv_t "conv-of-dead-process"; cv_t "nobody-owns-this"
cv_run
[ "$CV_RC" -eq 0 ] && ok "conv/dead pid: cycle completes (rc=0)" || bad "conv/dead pid: cycle rc=$CV_RC"
cv_alive "conv-of-dead-process" && bad "conv/dead pid: a leftover file of an exited process must not protect its sessionId" || ok "conv/dead pid: leftover session file of an exited process protects nothing"
grep -q "live-conversation scan: .* files=1 protected=0 gone=1 ignored_unreadable_dead=0" "$TRANSCRIPT_REAPER_LOG" \
  && ok "conv/dead pid: the scan summary counts the leftover as gone (files=1 protected=0 gone=1)" \
  || bad "conv/dead pid: scan summary missing or wrong: $(grep 'live-conversation scan:' "$TRANSCRIPT_REAPER_LOG" | tr '\n' ' ')"

# 3. ps cannot answer: unknown is never "dead" — the sessionId stays protected
cv_reset
cv_sf "$CV_DEAD" "conv-ps-cannot-say"
cv_t "conv-ps-cannot-say"; cv_t "nobody-owns-this"
PS="$CV_BIN/fake-ps"
cv_run
PS=ps
[ "$CV_RC" -eq 0 ] && ok "conv/ps unknown: cycle completes (rc=0)" || bad "conv/ps unknown: cycle rc=$CV_RC"
cv_alive "conv-ps-cannot-say" && ok "conv/ps unknown: ps failing is 'cannot tell', so the sessionId stays protected" || bad "conv/ps unknown: ps failing was read as dead and the conversation reaped"
grep -q "protecting conversation conv-ps-cannot-say: pid .* could not be checked" "$TRANSCRIPT_REAPER_LOG" \
  && ok "conv/ps unknown: the audit line says the pid could NOT be checked (not that it is alive)" \
  || bad "conv/ps unknown: audit line missing or claims more than was known: $(grep 'protecting conversation' "$TRANSCRIPT_REAPER_LOG" | tr '\n' ' ')"

# 4. the sessions dir cannot be read: the third state — abort, delete NOTHING
for CV_CASE in missing file; do
  cv_reset
  case "$CV_CASE" in
    missing) CV_SESS_USE="$CV_BIN/no-such-dir" ;;
    file)    CV_SESS_USE="$CV_BIN/not-a-dir" ;;
  esac
  cv_t "nobody-owns-this"; cv_t "bead-key-thies"
  cv_run
  [ "$CV_RC" -ne 0 ] && ok "conv/dir $CV_CASE: cycle aborts (rc=$CV_RC)" || bad "conv/dir $CV_CASE: rc=0 — went on without knowing which conversations are live"
  cv_alive "nobody-owns-this" && ok "conv/dir $CV_CASE: nothing reaped, not even an obviously dead+stale file" || bad "conv/dir $CV_CASE: reaped with the sessions dir unreadable"
  grep -q "live-conversation scan" "$TRANSCRIPT_REAPER_LOG" && grep -q "ABORT" "$TRANSCRIPT_REAPER_LOG" \
    && ok "conv/dir $CV_CASE: the abort names the live-conversation scan" || bad "conv/dir $CV_CASE: abort not logged by the live-conversation scan"
done
# mode 000: nothing; 111: can enter but not list (a glob finds nothing: it would LOOK empty); 444: can list but not open anything
if [ "$(id -u)" != "0" ]; then
  for CV_MODE in 000 111 444; do
    cv_reset
    mkdir -p "$CV_BIN/locked"; chmod "$CV_MODE" "$CV_BIN/locked"
    CV_SESS_USE="$CV_BIN/locked"
    cv_t "nobody-owns-this"
    cv_run
    chmod 755 "$CV_BIN/locked"
    [ "$CV_RC" -ne 0 ] && cv_alive "nobody-owns-this" \
      && ok "conv/dir unreadable (mode $CV_MODE): cycle aborts and reaps nothing" \
      || bad "conv/dir unreadable (mode $CV_MODE): rc=$CV_RC or the file was reaped — a dir that cannot be read was read as 'no live sessions'"
  done
fi

# 4b. an EMPTY sessions dir is a valid answer ("no process is running"), not a failure. Production runs the fetchers with
#     nullglob OFF (main() turns it on later), so the unexpanded pattern must be skipped; nullglob ON is covered too.
for CV_NG in 0 1; do
  cv_reset
  CV_NULLGLOB="$CV_NG"
  cv_t "nobody-owns-this"; cv_t "bead-key-thies"
  cv_run
  [ "$CV_RC" -eq 0 ] && ok "conv/empty dir (nullglob=$CV_NG): an empty sessions dir is 'nothing extra to protect', the cycle completes" || bad "conv/empty dir (nullglob=$CV_NG): rc=$CV_RC — an empty dir was read as a failure"
  cv_alive "nobody-owns-this" && bad "conv/empty dir (nullglob=$CV_NG): the cycle did not reap" || ok "conv/empty dir (nullglob=$CV_NG): the cycle reaps normally"
  cv_alive "bead-key-thies" && ok "conv/empty dir (nullglob=$CV_NG): session_key protection is unchanged" || bad "conv/empty dir (nullglob=$CV_NG): a session_key transcript was reaped"
done

# 5. a session file that cannot be read, with a LIVE pid behind it: cannot tell what it protects — abort
cv_reset
printf '{"pid": 12' > "$CV_SESS/$$.json"
cv_t "nobody-owns-this"; cv_t "bead-key-thies"
cv_run
[ "$CV_RC" -ne 0 ] && cv_alive "nobody-owns-this" \
  && ok "conv/corrupt+live: unreadable session file of a live pid aborts the cycle, nothing reaped" \
  || bad "conv/corrupt+live: rc=$CV_RC or reaped — a conversation that cannot be named was ignored"

# 5b. the same shape of failure, valid JSON with no sessionId / no pid / a hostile sessionId
CV_W80="$(printf '%080d' 0)"; CV_W81="$(printf '%081d' 0)"      # 80 and 81 characters of a valid id alphabet
for CV_CASE in no-sessionid empty-sessionid number-sessionid space-sessionid inner-space-sessionid dot-sessionid slash-sessionid long-sessionid dash-sessionid no-pid string-pid float-pid negative-pid traversal newline; do
  cv_reset
  case "$CV_CASE" in
    no-sessionid)    printf '{"pid":%s,"cwd":"/w"}\n' "$$" > "$CV_SESS/$$.json" ;;
    number-sessionid) printf '{"pid":%s,"sessionId":12345}\n' "$$" > "$CV_SESS/$$.json" ;;
    space-sessionid) printf '{"pid":%s,"sessionId":" conv-x"}\n' "$$" > "$CV_SESS/$$.json" ;;
    inner-space-sessionid) printf '{"pid":%s,"sessionId":"conv x"}\n' "$$" > "$CV_SESS/$$.json" ;;
    dot-sessionid)   printf '{"pid":%s,"sessionId":"conv.x"}\n' "$$" > "$CV_SESS/$$.json" ;;
    slash-sessionid) printf '{"pid":%s,"sessionId":"conv/x"}\n' "$$" > "$CV_SESS/$$.json" ;;
    empty-sessionid) printf '{"pid":%s,"sessionId":""}\n' "$$" > "$CV_SESS/$$.json" ;;
    dash-sessionid)  printf '{"pid":%s,"sessionId":"-f"}\n' "$$" > "$CV_SESS/$$.json" ;;   # grep -qxF "-f" would take it for an option
    long-sessionid)  printf '{"pid":%s,"sessionId":"%s"}\n' "$$" "$CV_W81" > "$CV_SESS/$$.json" ;;
    no-pid)          printf '{"sessionId":"conv-x","cwd":"/w"}\n' > "$CV_SESS/$$.json" ;;
    string-pid)      printf '{"pid":"%s","sessionId":"conv-x"}\n' "$$" > "$CV_SESS/$$.json" ;;
    float-pid)       printf '{"pid":%s.5,"sessionId":"conv-x"}\n' "$$" > "$CV_SESS/$$.json" ;;
    negative-pid)    printf '{"pid":-5,"sessionId":"conv-x"}\n' > "$CV_SESS/$$.json" ;;
    traversal)       printf '{"pid":%s,"sessionId":"../../etc/passwd"}\n' "$$" > "$CV_SESS/$$.json" ;;
    newline)         printf '%s\n' "{\"pid\":$$,\"sessionId\":\"conv-ok\\nnobody-owns-this\"}" > "$CV_SESS/$$.json" ;;
  esac
  cv_t "nobody-owns-this"
  cv_run
  [ "$CV_RC" -ne 0 ] && cv_alive "nobody-owns-this" \
    && ok "conv/$CV_CASE: a session file that does not say a usable pid + sessionId aborts the cycle, nothing reaped" \
    || bad "conv/$CV_CASE: rc=$CV_RC or reaped — the file was believed (or skipped) although it names no usable conversation"
done

# 5c. a file whose NAME is no pid, with a body that cannot be read: the owner cannot be shown gone — abort
cv_reset
printf '{' > "$CV_SESS/notes.json"
cv_t "nobody-owns-this"
cv_run
[ "$CV_RC" -ne 0 ] && cv_alive "nobody-owns-this" \
  && ok "conv/corrupt+no pid in name: an unreadable file that names no process aborts the cycle, nothing reaped" \
  || bad "conv/corrupt+no pid in name: rc=$CV_RC or reaped — the owner was assumed gone without proof"

# 5d. the id length bound is exactly 80: an 80-character id is a conversation (protected), 81 was refused above
cv_reset
cv_sf "$$" "$CV_W80"
cv_t "$CV_W80"; cv_t "nobody-owns-this"
cv_run
[ "$CV_RC" -eq 0 ] && cv_alive "$CV_W80" && ok "conv/80 chars: an id of exactly 80 characters is protected" || bad "conv/80 chars: rc=$CV_RC or the 80-character conversation was reaped"

# 6. unreadable file but its pid is provably dead: nothing to protect — the cycle must not be wedged forever by one stale file
cv_reset
printf '{"pid": 12' > "$CV_SESS/$CV_DEAD.json"
cv_t "nobody-owns-this"
cv_run
[ "$CV_RC" -eq 0 ] && ok "conv/corrupt+dead: unreadable leftover of an exited process does not abort the cycle" || bad "conv/corrupt+dead: rc=$CV_RC — one stale file wedges the reaper forever"
cv_alive "nobody-owns-this" && bad "conv/corrupt+dead: the cycle did not reap" || ok "conv/corrupt+dead: the cycle reaps normally"
grep -q "live-conversation scan: .* files=1 protected=0 gone=0 ignored_unreadable_dead=1" "$TRANSCRIPT_REAPER_LOG" \
  && ok "conv/corrupt+dead: the scan says the unreadable leftover was IGNORED, not lost (ignored_unreadable_dead=1)" \
  || bad "conv/corrupt+dead: scan summary missing or wrong: $(grep 'live-conversation scan:' "$TRANSCRIPT_REAPER_LOG" | tr '\n' ' ')"

# 7. other files in the dir are not session files: .key files and temp files are ignored (never parsed, never an abort)
cv_reset
printf 'not json at all' > "$CV_SESS/1234.0a0b0c0d.key"
printf '{' > "$CV_SESS/5678.json.tmp"
cv_sf "$$" "conv-in-use-by-athos"
cv_t "conv-in-use-by-athos"; cv_t "nobody-owns-this"
cv_run
[ "$CV_RC" -eq 0 ] && ok "conv/other files: .key and .tmp files in the dir do not abort the cycle" || bad "conv/other files: rc=$CV_RC — a non-session file was parsed"
cv_alive "conv-in-use-by-athos" && ok "conv/other files: the real session file still protects its conversation" || bad "conv/other files: the real session file was lost among the others"

# 8. the id the capture slice writes into the session bead (no live process: the post-reboot window)
cv_reset
cv_bd '[{"id":"ga-crew1","issue_type":"session","status":"open","metadata":{"session_key":"bead-key-thies","session.live_conversation_id":"53bf2758-aaaa-4bbb-8ccc-dddd00001111","state":"asleep"}}]'
cv_t "53bf2758-aaaa-4bbb-8ccc-dddd00001111"; cv_t "nobody-owns-this"
cv_run
[ "$CV_RC" -eq 0 ] && ok "captured id: cycle completes (rc=0)" || bad "captured id: cycle rc=$CV_RC"
cv_alive "53bf2758-aaaa-4bbb-8ccc-dddd00001111" \
  && ok "captured id: a conversation id in a session bead's metadata survives with NO live process (the window between a reboot and the resume)" \
  || bad "captured id: the id recorded in the session bead was reaped"
cv_alive "nobody-owns-this" && bad "captured id: a transcript nobody owns must still be reaped" || ok "captured id: a transcript nobody owns is still reaped"

# 8b. no key name is hard-coded: whatever key the capture slice picks, a conversation id in the metadata counts
cv_reset
cv_bd '[{"id":"ga-crew1","issue_type":"session","status":"open","metadata":{"session_key":"bead-key-thies","whatever_key_the_capture_slice_picks":"d150ee9b-aaaa-4bbb-8ccc-dddd00002222","command":"/Users/athos/gt/some/very long command with spaces"}}]'
cv_t "d150ee9b-aaaa-4bbb-8ccc-dddd00002222"; cv_t "nobody-owns-this"
cv_run
cv_alive "d150ee9b-aaaa-4bbb-8ccc-dddd00002222" && ok "captured id: protected under any metadata key name (no name to drift from the capture slice)" || bad "captured id: protection depends on a key name"

# 9. bd cannot answer, or answers something that is not a list of beads: abort, delete NOTHING
# (each case also names the exact abort message: two branches that abort for different reasons must not hide each other)
for CV_CASE in rc1 empty garbage object keyed-object nulls nometa-string; do
  cv_reset
  CV_MSG="did not answer a list of beads"
  case "$CV_CASE" in
    rc1)           cv_bd '[{"id":"ga-crew1","metadata":{"session_key":"some-key"}}]' 1;    CV_MSG="failed (rc=1)" ;;   # printed a perfectly good list and still exited 1: not trusted
    empty)         cv_bd '' 0;                                                             CV_MSG="failed (rc=0) or returned nothing" ;;
    garbage)       cv_bd 'Error: dolt unreachable' 0 ;;
    object)        cv_bd '{"issues":[]}' 0 ;;
    keyed-object)  cv_bd '{"ga-crew1":{"id":"ga-crew1","metadata":{"session_key":"k"}}}' 0 ;;
    nulls)         cv_bd '[null]' 0 ;;
    nometa-string) cv_bd '[{"id":"ga-crew1","metadata":"not-an-object"}]' 0 ;;
  esac
  cv_t "nobody-owns-this"; cv_t "bead-key-thies"
  cv_run
  [ "$CV_RC" -ne 0 ] && ok "captured id/bd $CV_CASE: cycle aborts (rc=$CV_RC)" || bad "captured id/bd $CV_CASE: rc=0 — went on with an unreadable bead list"
  cv_alive "nobody-owns-this" && ok "captured id/bd $CV_CASE: nothing reaped" || bad "captured id/bd $CV_CASE: reaped with the bead list unreadable"
  grep -q "ABORT: captured-id scan: .*$CV_MSG" "$TRANSCRIPT_REAPER_LOG" \
    && ok "captured id/bd $CV_CASE: the abort is the captured-id scan's, for the right reason" || bad "captured id/bd $CV_CASE: expected an ABORT from the captured-id scan saying '$CV_MSG', log: $(grep ABORT "$TRANSCRIPT_REAPER_LOG" | tr '\n' ' ')"
done

# 9b. gc lists live sessions but bd answers an empty list: the two reads of the same store contradict — not believed
cv_reset
cv_bd '[]' 0
cv_t "nobody-owns-this"
cv_run
[ "$CV_RC" -ne 0 ] && cv_alive "nobody-owns-this" \
  && ok "captured id/bd []: an empty bead list while gc lists live sessions aborts the cycle (a broken query, not 'no captured ids')" \
  || bad "captured id/bd []: rc=$CV_RC or reaped — empty was believed against a non-empty session list"
grep -q "ABORT: captured-id scan: .*returned no session bead although live sessions are listed" "$TRANSCRIPT_REAPER_LOG" \
  && ok "captured id/bd []: the abort says why (the two reads contradict each other)" || bad "captured id/bd []: wrong or missing abort message: $(grep ABORT "$TRANSCRIPT_REAPER_LOG" | tr '\n' ' ')"

# 9b2. ...but when NOTHING is live anywhere (no session listed, no process, no bead) an empty bead list is just the truth: the cycle runs
cv_reset
CV_GC_USE="$CV_BIN/fake-gc-empty"
cv_bd '[]' 0
cv_t "nobody-owns-this"
cv_run
[ "$CV_RC" -eq 0 ] && ok "captured id/bd []: an empty bead list with no live session anywhere is a valid answer (rc=0)" || bad "captured id/bd []: rc=$CV_RC — a genuinely empty city was read as a failure"
cv_alive "nobody-owns-this" && bad "captured id/bd []: with nothing live the cycle must reap" || ok "captured id/bd []: with nothing live the cycle reaps"

# 9c. a bead with NO metadata key at all is fine (bd omits empty fields): no captured id, no abort
cv_reset
cv_bd '[{"id":"ga-crew1","issue_type":"session","status":"open"},{"id":"ga-wisp-y","issue_type":"session","status":"open","metadata":null}]'
cv_t "nobody-owns-this"
cv_run
[ "$CV_RC" -eq 0 ] && ok "captured id/bd: beads without a metadata key are 'nothing captured', not a failure" || bad "captured id/bd: rc=$CV_RC for beads with no metadata"

# 9d. the query is the proven idiom (nightly-reboot.sh / quality-gate-dispatcher.sh), and wide enough: every NON-closed session bead, no row limit
cv_reset
cv_run
CV_ARGS="$(tr '\n' '|' < "$CV_BIN/bd.args")"
[ "$CV_ARGS" = "-C|/Users/athos/gt/.gascity-gastown-hq|query|--json|type=session AND status!=closed|--limit=0|" ] \
  && ok "captured id/bd: asks for 'type=session AND status!=closed' with --limit=0 in the city store" \
  || bad "captured id/bd: unexpected bd arguments: $CV_ARGS"

# 9e. exactly WHICH metadata values reach the live-keys file: strings of 1-80 characters without whitespace, and nothing else; the
#     file is APPENDED to (what _fetch_live_keys wrote is still there). Called directly: the content of the file is the assertion.
cv_reset
CV_OUT="$(mktemp /tmp/transcript-reaper-selftest-cvout.XXXXXX)"
printf 'pre-existing\n' > "$CV_OUT"
cv_bd "$(printf '[{"id":"a","metadata":{"k1":"short-id","k2":"has space","k3":"%s","k4":5,"k5":{"n":"nested-not-seen"},"k6":"","k7":true,"k8":"%s","k10":"tab\\there","k11":null}},{"id":"b"},{"id":"c","metadata":{"k1":"short-id"}}]' "$CV_W81" "$CV_W80")"
BD="$CV_BIN/fake-bd"
_fetch_captured_ids "$CV_OUT"; CV_URC=$?
[ "$CV_URC" -eq 0 ] && ok "captured id/content: the scan succeeds on a mixed bag of metadata (rc=0)" || bad "captured id/content: rc=$CV_URC"
CV_GOT="$(sort "$CV_OUT" | tr '\n' '|')"
CV_WANT="$(printf '%s\n' pre-existing short-id short-id "$CV_W80" | sort | tr '\n' '|')"
[ "$CV_GOT" = "$CV_WANT" ] \
  && ok "captured id/content: appended exactly the single-word strings of 1-80 chars (not numbers, objects, '', booleans, null, 81 chars, text with whitespace) and kept what was there" \
  || bad "captured id/content: live-keys file is '$CV_GOT', wanted '$CV_WANT'"
grep -q "captured-id scan: session beads=3 values kept=" "$TRANSCRIPT_REAPER_LOG" \
  && ok "captured id/content: the scan summary counts the beads read" || bad "captured id/content: scan summary missing: $(grep 'captured-id scan' "$TRANSCRIPT_REAPER_LOG" | tr '\n' ' ')"
rm -f "$CV_OUT"

# 9f. a live-keys file that cannot be WRITTEN is not "nothing to protect": both scans abort (the reaper runs under disk pressure,
#     and a write that fails must not leave a conversation unprotected without a word). Skipped as root: root writes a 444 file.
if [ "$(id -u)" != "0" ]; then
  cv_reset
  cv_sf "$$" "conv-in-use-by-athos"
  cv_bd '[{"id":"ga-crew1","metadata":{"session_key":"some-key"}}]'
  CV_OUT="$(mktemp /tmp/transcript-reaper-selftest-cvout.XXXXXX)"; chmod 444 "$CV_OUT"
  SESSIONS_DIR="$CV_SESS"; BD="$CV_BIN/fake-bd"
  _fetch_live_conversations "$CV_OUT" 2>/dev/null; CV_URC=$?
  [ "$CV_URC" -ne 0 ] && grep -q "ABORT: live-conversation scan: could not record" "$TRANSCRIPT_REAPER_LOG" \
    && ok "write failure: the live-conversation scan aborts when it cannot record a protected id" \
    || bad "write failure: live-conversation scan rc=$CV_URC — a protected id was lost without a word"
  _fetch_captured_ids "$CV_OUT" 2>/dev/null; CV_URC=$?
  [ "$CV_URC" -ne 0 ] && grep -q "ABORT: captured-id scan: could not record" "$TRANSCRIPT_REAPER_LOG" \
    && ok "write failure: the captured-id scan aborts when it cannot record the ids" \
    || bad "write failure: captured-id scan rc=$CV_URC — the captured ids were lost without a word"
  chmod 644 "$CV_OUT"; rm -f "$CV_OUT"
fi

# 10. a REAL process: protected while it runs, released the moment it exits (the session file it leaves behind is just a leftover)
cv_reset
sleep 120 & CV_LIVE=$!
cv_sf "$CV_LIVE" "conv-of-real-process"
cv_t "conv-of-real-process"
cv_run
cv_alive "conv-of-real-process" && ok "conv/real process: protected while its process runs" || bad "conv/real process: reaped while its process was running"
kill "$CV_LIVE" 2>/dev/null; wait "$CV_LIVE" 2>/dev/null
cv_run
cv_alive "conv-of-real-process" && bad "conv/real process: still protected after its process exited (leftover pins the transcript)" || ok "conv/real process: released once the process exited"

# 12. the production entry point: the script as a SUBPROCESS (what dolt-disk-floor-guard.sh runs), configured ONLY through its
#     env names. The scenarios above set the internal variables, which would hide a typo in an env name. With PS_BIN faked, the
#     'exited' pid reads as cannot-tell, so its conversation survives only if PS_BIN really reaches the script.
cv_reset
cv_sf "$$" "conv-in-use-by-athos"
cv_sf "$CV_DEAD" "conv-ps-cannot-say"
cv_t "conv-in-use-by-athos"; cv_t "conv-ps-cannot-say"; cv_t "nobody-owns-this"
env -u TRANSCRIPT_REAPER_LIB TRANSCRIPT_REAPER_ROOT="$CV_ROOT" TRANSCRIPT_REAPER_SESSIONS_DIR="$CV_SESS" \
    GC_BIN="$CV_BIN/fake-gc" BD_BIN="$CV_BIN/fake-bd" PS_BIN="$CV_BIN/fake-ps" TRANSCRIPT_REAPER_MIN_AGE_HOURS=24 bash "$SCRIPT"
CV_RC=$?
[ "$CV_RC" -eq 0 ] && ok "entry point: the script run as a subprocess completes (rc=0) when configured through env names only" || bad "entry point: subprocess rc=$CV_RC — an env name (TRANSCRIPT_REAPER_SESSIONS_DIR / BD_BIN / PS_BIN / GC_BIN) does not reach the script"
cv_alive "conv-in-use-by-athos" && ok "entry point: TRANSCRIPT_REAPER_SESSIONS_DIR reaches the script (the live conversation survives)" || bad "entry point: live conversation reaped through the real entry point"
cv_alive "conv-ps-cannot-say" && ok "entry point: PS_BIN reaches the script (a ps that cannot answer protects, it does not read as gone)" || bad "entry point: PS_BIN did not reach the script"
cv_alive "nobody-owns-this" && bad "entry point: nobody's transcript must be reaped by the real entry point" || ok "entry point: nobody's transcript reaped (the subprocess really reaped)"

# 12b. the production defaults: a wrong default is a reaper that aborts on every cycle, silently, in production
CV_DEFAULTS="$(env -u TRANSCRIPT_REAPER_SESSIONS_DIR -u BD_BIN -u PS_BIN SCRIPT_PATH="$SCRIPT" bash -c 'TRANSCRIPT_REAPER_LIB=1 . "$SCRIPT_PATH"; echo "$SESSIONS_DIR|$BD|$PS"' 2>/dev/null)"
[ "$CV_DEFAULTS" = "/Users/athos/.claude/sessions|bd|ps" ] \
  && ok "defaults: sessions dir is the sibling of the projects root (/Users/athos/.claude/sessions), bd and ps come from PATH" \
  || bad "defaults: expected '/Users/athos/.claude/sessions|bd|ps', got '$CV_DEFAULTS'"

# 11. _pid_liveness itself: 0 alive, 1 gone, 2 cannot tell (never 'gone' for something that was not understood)
_pid_liveness "$$";        [ $? -eq 0 ] && ok "pid_liveness: this process → 0 (alive)" || bad "pid_liveness: own pid not alive"
_pid_liveness "$CV_DEAD";  [ $? -eq 1 ] && ok "pid_liveness: an exited pid → 1 (gone)" || bad "pid_liveness: exited pid not reported gone"
# a ps that says "alive" to anything: the input check must refuse a non-pid BEFORE asking ps (otherwise this ps would answer 0)
cat > "$CV_BIN/fake-ps-alive" <<'FAKEPS'
#!/bin/bash
echo "  1234"
exit 0
FAKEPS
chmod +x "$CV_BIN/fake-ps-alive"
for CV_PID in "" abc 0 007 -5 +5 "12 34"; do
  PS="$CV_BIN/fake-ps-alive"; _pid_liveness "$CV_PID"; CV_PRC=$?; PS=ps
  [ "$CV_PRC" -eq 2 ] && ok "pid_liveness: '$CV_PID' is not a pid → 2 (cannot tell), refused before ps is asked" || bad "pid_liveness: '$CV_PID' reached ps and read as rc=$CV_PRC"
done
PS="$CV_BIN/fake-ps"; _pid_liveness "$$"; CV_PRC=$?; PS=ps
[ "$CV_PRC" -eq 2 ] && ok "pid_liveness: ps failing (rc 3 + message) → 2 (cannot tell), not 'gone'" || bad "pid_liveness: ps failure read as rc=$CV_PRC"
PS="$CV_BIN/fake-ps1"; _pid_liveness "$$"; CV_PRC=$?; PS=ps
[ "$CV_PRC" -eq 2 ] && ok "pid_liveness: ps exiting 1 WITH a complaint → 2 (cannot tell): only a SILENT rc 1 means 'no such process'" || bad "pid_liveness: ps rc 1 + message read as rc=$CV_PRC (a complaint was taken for 'gone')"
PS="$CV_BIN/fake-ps2s"; _pid_liveness "$$"; CV_PRC=$?; PS=ps
[ "$CV_PRC" -eq 2 ] && ok "pid_liveness: ps dying silently with rc 2 → 2 (cannot tell): silence alone is not 'no such process'" || bad "pid_liveness: a silent ps with rc 2 read as rc=$CV_PRC"

# 11b. the metadata extraction step crashing is a failure, not "no ids" (the dropped protection would be silent)
cv_reset
cv_bd '[{"id":"ga-crew1","metadata":{"session_key":"some-key"}}]'
CV_OUT="$(mktemp /tmp/transcript-reaper-selftest-cvout.XXXXXX)"
BD="$CV_BIN/fake-bd"
( PATH="$CV_BIN/jq-shim:$PATH"; _fetch_captured_ids "$CV_OUT" 2>/dev/null ); CV_URC=$?
[ "$CV_URC" -ne 0 ] && grep -q "ABORT: captured-id scan: could not extract" "$TRANSCRIPT_REAPER_LOG" \
  && ok "captured id/jq crash: a jq that fails on the extraction aborts the scan (not read as 'no captured ids')" \
  || bad "captured id/jq crash: rc=$CV_URC — a crashed extraction was read as an empty answer"
rm -f "$CV_OUT"

chmod 755 "$CV_BIN/locked" 2>/dev/null
rm -rf "$CV_ROOT" "$CV_SESS" "$CV_BIN"

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

# main()'s older scenarios from here on isolate the reap logic itself: the two fetchers added by
# ga-esorlre.1 (covered end to end in the section above) are stubbed to "nothing extra protected",
# so these scenarios keep testing exactly what they always tested.
_fetch_live_conversations() { return 0; }
_fetch_captured_ids() { return 0; }
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
echo "=== main(): lowered default (24h) — suspended-in-band survives, newly-stale dead is reaped (ga-5ppqo) ==="
# Fixture ages chosen INSIDE the 24h-72h band ga-5ppqo measured as 82% of
# total volume — previously unreachable no matter how well the reaper ran,
# now exactly the band the lowered threshold must handle correctly:
#   proj/suspended-30h.jsonl — 30h old, session IS in the (stubbed) live set
#     (simulates a suspended/asleep session `gc session list`'s default
#     listing still tracks) → must survive: liveness beats age regardless of
#     how low the threshold goes. This is the literal risk ga-5ppqo's own
#     acceptance criteria calls out: "o teste tem que incluir uma sessao
#     SUSPENSA de mais de 24h".
#   proj/dead-30h.jsonl      — 30h old, DEAD (absent from the live set) —
#     was NOT reachable at the old 72h default; must now be reaped at 24h.
#     This is the actual space the fix recovers.
#   proj/dead-20h.jsonl      — 20h old, DEAD — still inside the (shorter)
#     grace window; must still survive. The grace period isn't gone, just
#     shorter.
BAND_ROOT="$(mktemp -d /tmp/transcript-reaper-selftest-band.XXXXXX)"
mkdir -p "$BAND_ROOT/proj"
: > "$BAND_ROOT/proj/suspended-30h.jsonl"
: > "$BAND_ROOT/proj/dead-30h.jsonl"
: > "$BAND_ROOT/proj/dead-20h.jsonl"

BAND_NOW_EPOCH=$(date +%s)
touch -t "$(date -r $((BAND_NOW_EPOCH - 30*3600)) +%Y%m%d%H%M.%S)" "$BAND_ROOT/proj/suspended-30h.jsonl"
touch -t "$(date -r $((BAND_NOW_EPOCH - 30*3600)) +%Y%m%d%H%M.%S)" "$BAND_ROOT/proj/dead-30h.jsonl"
touch -t "$(date -r $((BAND_NOW_EPOCH - 20*3600)) +%Y%m%d%H%M.%S)" "$BAND_ROOT/proj/dead-20h.jsonl"

# Stub liveness: only "suspended-30h" is in the live set — exactly how a real
# suspended session appears in `gc session list`'s default (active +
# suspended/asleep + anything not closed) output.
_fetch_live_keys() { printf 'suspended-30h\n' > "$1"; }

# shellcheck disable=SC2034  # read by main() in the sourced script
TRANSCRIPT_ROOT="$BAND_ROOT"
ENABLED=1
DRY_RUN=0
MIN_AGE_HOURS=24
SELF_SESSION_ID=""

main

[ -f "$BAND_ROOT/proj/suspended-30h.jsonl" ] \
  && ok "main(): suspended session in the 24-72h band survives at the lowered threshold (liveness beats age)" \
  || bad "main(): suspended-30h.jsonl was wrongly reaped — THE EXACT RISK ga-5ppqo's fix must not introduce"
[ -f "$BAND_ROOT/proj/dead-30h.jsonl" ] \
  && bad "main(): dead session at 30h should now be reaped at the lowered 24h threshold (was unreachable at 72h)" \
  || ok "main(): dead session at 30h now reaped — the actual space ga-5ppqo's fix recovers"
[ -f "$BAND_ROOT/proj/dead-20h.jsonl" ] \
  && ok "main(): dead session at 20h still survives — grace period holds, just shorter" \
  || bad "main(): dead-20h.jsonl reaped before its (lowered) grace period elapsed"

rm -rf "$BAND_ROOT"

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
