#!/usr/bin/env bash
# gate-reviewer-orphan-clear.selftest.sh — Prove the ga-flfo age/creating guard
# in scripts/gate-reviewer-orphan-clear.sh in isolation, with NO live Dolt/gc/
# launchd/tmux.
#
# Bug ga-flfo: gate-reviewer-orphan-clear.sh (the gt-bewtm stopgap janitor) had
# NO age floor and read STATE from the wrong `gc session list` column ($4 =
# REASON, not STATE). Its StartInterval=189s sweep ran INSIDE every reviewer's
# real ~210s deferred-start boot window, so `gc session peek` reporting
# "session not found" for a not-yet-booted session was indistinguishable from
# a genuinely-dead one — the sweep closed reviewers mid-boot (observed live:
# w4x6vg reaped 32s after spawn, uraowb at 48s).
#
# The fix adds a pure orphan_clear_decision() gate: state=active is kept
# (working), state=creating is kept (not born yet — NEVER a death signal,
# regardless of age), and anything younger than MIN_AGE_SECS (default 360s,
# comfortably above the observed ~210s worst case) is kept. Only a session
# that clears ALL of those AND fails a live `gc session peek` gets closed.
#
# This harness SOURCES the REAL script (GATE_REVIEWER_ORPHAN_CLEAR_SOURCE_ONLY)
# to unit-test its REAL pure decision function, proves the two NB-VERIFY-ARTIFACT
# senses (booting/young survives; genuinely-old-and-dead still reaped), runs an
# explicit MUTATION TEST proving the guard is load-bearing (remove it → the same
# scenario that must survive in sense #1 would instead be reaped), and finally
# DRIFT-GUARDS the live script so a future refactor that drops the guard, the
# --json switch, or the state fetch fails loudly. Exit 0 iff every assertion
# holds.
#
# ga-2hd02v.1.23 (sections 8-10): the ga-flfo floor (360s) protected `creating`
# but not `start-pending` — the state of a session that has been ACCEPTED and is
# waiting for the reconciler to wake it (patrol_interval=120s x max_wakes_per_tick=2
# = a queue of 2-10 min on this city, measured 481s on 19/10). `gc session peek`
# answers "gone" for it exactly as for a dead one, so the sweep closed a remote
# gate-reviewer at age=428s, 4s after the controller started it; the task nudge
# stayed in the closed bead's queue and the verdict bead lost its assignee: the
# reviewer came up untasked and the gate-run burned 56 min with 0 verdict.
#   8. pure: start-pending has its own, longer floor; the re-check decision.
#   9. the REAL script end to end, with a stub `gc` (no live gc/Dolt/tmux).
#  10. drift-guard of the new wiring.
# ORPHAN_CLEAR_SCRIPT overrides the script under test (used to prove sections 8-9
# FAIL on the pre-fix script).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gate-reviewer-orphan-clear.sh lives in scripts/, three levels up from
# packs/town-deltas/assets/ where this selftest lives.
SCRIPT="${ORPHAN_CLEAR_SCRIPT:-$SELF_DIR/../../../scripts/gate-reviewer-orphan-clear.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

[ -f "$SCRIPT" ] || { echo "FATAL: script not found at $SCRIPT"; exit 1; }

# ── Load the REAL helpers from the script (source-only = no live sweep) ──────
GATE_REVIEWER_ORPHAN_CLEAR_SOURCE_ONLY=1 source "$SCRIPT" \
  || { echo "FATAL: could not source gate-reviewer-orphan-clear.sh in source-only mode"; exit 1; }

type orphan_clear_decision >/dev/null 2>&1 || { echo "FATAL: orphan_clear_decision not defined"; exit 1; }
type session_age_secs      >/dev/null 2>&1 || { echo "FATAL: session_age_secs not defined"; exit 1; }

MIN_AGE=360

echo "── 1. orphan_clear_decision — active/creating are NEVER reap candidates ──"
eq "active, age 0 → keep_active"           "$(orphan_clear_decision active 0 "$MIN_AGE")"      "keep_active"
eq "active, age huge → keep_active"        "$(orphan_clear_decision active 999999 "$MIN_AGE")" "keep_active"
eq "(ga-flfo NB-VERIFY sense 1) creating, age 30s → keep_creating (NOT reaped/dead)" \
   "$(orphan_clear_decision creating 30 "$MIN_AGE")" "keep_creating"
eq "creating, age huge → STILL keep_creating (never a death signal by itself)" \
   "$(orphan_clear_decision creating 999999 "$MIN_AGE")" "keep_creating"

echo "── 2. orphan_clear_decision — the age floor protects any OTHER state too ──"
eq "asleep, age 0 → keep_young"                  "$(orphan_clear_decision asleep 0 "$MIN_AGE")"   "keep_young"
eq "asleep, age just under MIN_AGE → keep_young" "$(orphan_clear_decision asleep 359 "$MIN_AGE")" "keep_young"
eq "asleep, age EXACTLY MIN_AGE → eligible (>=)" "$(orphan_clear_decision asleep 360 "$MIN_AGE")" "eligible"

echo "── 3. (ga-flfo NB-VERIFY sense 2) genuinely old + non-active/creating → eligible (still reaped by the peek stage) ──"
eq "asleep, age well over MIN_AGE → eligible"    "$(orphan_clear_decision asleep 600 "$MIN_AGE")"  "eligible"
eq "dormant, age well over MIN_AGE → eligible"   "$(orphan_clear_decision dormant 600 "$MIN_AGE")" "eligible"
eq "drained, age well over MIN_AGE → eligible"   "$(orphan_clear_decision drained 600 "$MIN_AGE")" "eligible"

echo "── 4. fail-SAFE on unknown/garbage age (never reap on incomplete info) ──"
eq "empty age → keep_age_unknown"          "$(orphan_clear_decision asleep '' "$MIN_AGE")"    "keep_age_unknown"
eq "non-numeric age → keep_age_unknown"    "$(orphan_clear_decision asleep 'NaN' "$MIN_AGE")"  "keep_age_unknown"

echo "── 5. session_age_secs — canonical timestamp math ──"
eq "created 360s before now → age 360"     "$(session_age_secs '2020-01-01T00:00:00Z' 1577837160)" "360"
eq "created NOW → age 0"                   "$(session_age_secs '2020-01-01T00:00:00Z' 1577836800)" "0"
eq "empty created_at → unknown (empty)"    "$(session_age_secs '' 1577837160)" ""
eq "unparseable created_at → unknown"      "$(session_age_secs 'not-a-date' 1577837160)" ""
eq "±HH:MM offset parses (matches gc's live -03:00 form)" \
   "$(session_age_secs '2020-01-01T00:00:00-03:00' 1577847960)" "360"

echo "── 6. MUTATION TEST — the age/creating guard is load-bearing ──"
# Reconstruct EXACTLY the pre-fix decision (no age floor, no creating check —
# the literal original script's logic: only 'active' was ever skipped, and
# even that fast-path read the WRONG list column in practice, so in the real
# pre-fix script not even 'active' reliably held — this mirror is deliberately
# the BEST CASE for the old code, to make the mutation test conservative).
# If sense-1's assertion above (creating, 30s → keep_creating) is to mean
# anything, this pre-fix function MUST make the OPPOSITE call for the SAME
# input — proving assertion (1) actually exercises the guard rather than
# passing vacuously (i.e. even a reverted fix would still pass it).
orphan_clear_decision_PRE_FIX() {
  local state="$1"
  case "$state" in
    active) echo "keep_active"; return 0 ;;
  esac
  echo "eligible"   # pre-fix: everything else goes straight to the peek probe
}
_mutant_verdict="$(orphan_clear_decision_PRE_FIX creating 30)"
eq "pre-fix mirror (no guard) reads a 30s-old booting session as 'eligible' (would be peeked+closed)" \
   "$_mutant_verdict" "eligible"
_fixed_verdict="$(orphan_clear_decision creating 30 "$MIN_AGE")"
[ "$_fixed_verdict" != "$_mutant_verdict" ] \
  && ok "FIXED ($_fixed_verdict) vs PRE-FIX ($_mutant_verdict) verdicts diverge on the sense-1 scenario — the guard is the actual cause, not a coincidence" \
  || bad "FIXED and PRE-FIX agree — the guard changed nothing (sense-1 assertion would pass even with the fix reverted)"

echo "── 7. drift-guard: the live script still has the ga-flfo guard wired in ──"
has "$SCRIPT" 'orphan_clear_decision\(\)'                     "pure decision function is defined"
has "$SCRIPT" 'creating\) echo "keep_creating"'               "state=creating is excluded from reap eligibility"
has "$SCRIPT" 'GATE_REVIEWER_ORPHAN_CLEAR_MIN_AGE_SECS:-360'  "MIN_AGE_SECS defaults to 360s (>= observed ~210s boot)"
has "$SCRIPT" 'session list --json'                           "sweep uses --json (fixes the wrong-column state bug)"
has "$SCRIPT" 'template.lower\(\)'                            "template filter preserves gate-reviewer + refino-gate-reviewer scope"
has "$SCRIPT" 'decision=\$\(orphan_clear_decision'            "sweep loop actually calls the decision function (not a leftover unused def)"
has "$SCRIPT" 'gc session peek "\$sid"'                       "eligible sessions still go through a live peek before closing (defense in depth)"
has "$SCRIPT" 'GATE_REVIEWER_ORPHAN_CLEAR_SOURCE_ONLY'        "script is sourceable in source-only mode (this selftest depends on it)"

echo "── 8. (ga-2hd02v.1.23) start-pending = queued for a wake, NOT dead: its own, longer floor ──"
SP_MIN=1500
# The measured incident: start-pending, age 428s, peek gone → must be KEPT.
eq "start-pending age 428s (the 19/10 incident) → keep_start_pending" \
   "$(orphan_clear_decision start-pending 428 "$MIN_AGE" "$SP_MIN")" "keep_start_pending"
eq "start-pending age 360s (the old floor) → keep_start_pending" \
   "$(orphan_clear_decision start-pending 360 "$MIN_AGE" "$SP_MIN")" "keep_start_pending"
eq "start-pending age 1499s → keep_start_pending" \
   "$(orphan_clear_decision start-pending 1499 "$MIN_AGE" "$SP_MIN")" "keep_start_pending"
eq "start-pending age EXACTLY the start-pending floor → eligible (>=)" \
   "$(orphan_clear_decision start-pending 1500 "$MIN_AGE" "$SP_MIN")" "eligible"
eq "start-pending stuck far past the floor → eligible (the safety net still works)" \
   "$(orphan_clear_decision start-pending 4000 "$MIN_AGE" "$SP_MIN")" "eligible"
eq "no 4th arg → the built-in default floor protects a 428s start-pending" \
   "$(orphan_clear_decision start-pending 428 "$MIN_AGE")" "keep_start_pending"
eq "garbage 4th arg → falls back to the default, still protects" \
   "$(orphan_clear_decision start-pending 428 "$MIN_AGE" 'x')" "keep_start_pending"
eq "start-pending with unknown age → keep_age_unknown (fail-safe unchanged)" \
   "$(orphan_clear_decision start-pending '' "$MIN_AGE" "$SP_MIN")" "keep_age_unknown"
eq "NON-REGRESSION: asleep at 360s is still eligible (only start-pending got the longer floor)" \
   "$(orphan_clear_decision asleep 360 "$MIN_AGE" "$SP_MIN")" "eligible"
eq "NON-REGRESSION: draining at 980s is still eligible" \
   "$(orphan_clear_decision draining 980 "$MIN_AGE" "$SP_MIN")" "eligible"
eq "NON-REGRESSION: creating is still keep_creating" \
   "$(orphan_clear_decision creating 30 "$MIN_AGE" "$SP_MIN")" "keep_creating"

type orphan_clear_recheck_decision >/dev/null 2>&1 \
  || { bad "orphan_clear_recheck_decision not defined"; }
if type orphan_clear_recheck_decision >/dev/null 2>&1; then
  echo "── 8b. re-read right before the close: only an UNCHANGED, READABLE state may be closed ──"
  eq "same state → proceed"                          "$(orphan_clear_recheck_decision asleep asleep)"            "proceed"
  eq "snapshot asleep, now creating → keep_moved"    "$(orphan_clear_recheck_decision asleep creating)"          "keep_moved"
  eq "snapshot start-pending, now creating (the 19/10 race) → keep_moved" \
     "$(orphan_clear_recheck_decision start-pending creating)" "keep_moved"
  eq "snapshot start-pending, now active → keep_moved" "$(orphan_clear_recheck_decision start-pending active)"  "keep_moved"
  eq "re-read empty (session gone or read failed) → keep_unreadable (never close on incomplete info)" \
     "$(orphan_clear_recheck_decision asleep '')" "keep_unreadable"
fi

echo "── 9. the REAL script end to end (stub gc; cwd/LOG redirected to a temp dir) ──"
T9="$(mktemp -d "${TMPDIR:-/tmp}/orphan-clear-selftest.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
trap 'rm -rf "$T9"' EXIT
mkdir -p "$T9/bin" "$T9/city"

# A copy of the script under test with ONLY its two hard-coded live paths swapped, so neither the
# pre-fix nor the fixed script can touch the live city log. Fail loudly if the swap did not happen.
sed -e "s|^cd /Users/athos/gt/.gascity-gastown-hq .*|cd \"$T9/city\" \|\| exit 0|" \
    -e "s|^LOG=.*|LOG=\"$T9/orphan.log\"|" "$SCRIPT" > "$T9/script.sh"
grep -q "^LOG=\"$T9/orphan.log\"" "$T9/script.sh" && grep -q "^cd \"$T9/city\"" "$T9/script.sh" \
  && ok "harness: live cwd and LOG paths of the script under test redirected to the temp dir" \
  || { bad "harness: could not redirect the script's cwd/LOG (the script changed shape?) — refusing to run it"; echo "SELFTEST FAILED"; exit 1; }

# Stub gc. `session list --json` serves $STUB/list.N (N = 1st call, 2nd call, ...; the last one repeats),
# `session peek` exits $STUB/peek_rc, `session close` is RECORDED (never executed).
cat > "$T9/bin/gc" <<'STUB'
#!/bin/bash
set -u
S="${STUB_DIR:?}"
case "${1:-} ${2:-}" in
  "session list")
    n=$(cat "$S/list.calls" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$S/list.calls"
    f="$S/list.$n"; [ -f "$f" ] || f=$(ls "$S"/list.[0-9]* 2>/dev/null | grep -v calls | sort -t. -k2 -n | tail -1)
    [ -f "$S/list.fail.$n" ] && exit 1
    cat "$f" ;;
  "session peek")  exit "$(cat "$S/peek_rc" 2>/dev/null || echo 1)" ;;
  "session close") echo "$3" >> "$S/closed"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T9/bin/gc"

iso_ago() { python3 -c 'import sys,datetime
print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
# session_json <id> <state> <age_secs> [template]
session_json() { printf '[{"id":"%s","state":"%s","created_at":"%s","template":"%s"}]' "$1" "$2" "$(iso_ago "$3")" "${4:-gate-reviewer-remote}"; }
# run_sweep <name> : fresh STUB dir per scenario; caller pre-fills $S/list.1 (+ list.2, peek_rc)
run_sweep() {
  S="$T9/$1"; rm -rf "$S"; mkdir -p "$S"; : > "$T9/orphan.log"
}
do_sweep() { STUB_DIR="$S" PATH="$T9/bin:$PATH" bash "$T9/script.sh" >/dev/null 2>&1; }
closed_ids() { cat "$S/closed" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }

echo "  scenario A: the 19/10 incident — remote reviewer start-pending 428s, peek gone"
run_sweep A; session_json ga-wisp-is807 start-pending 428 > "$S/list.1"; echo 1 > "$S/peek_rc"
do_sweep
eq "A: session NOT closed (it is waiting for its wake tick, not dead)" "$(closed_ids)" ""
has "$T9/orphan.log" 'kept_start_pending=1' "A: the sweep line counts it as kept_start_pending"

echo "  scenario B: start-pending far past the floor (2400s), peek gone, state unchanged on re-read"
run_sweep B; session_json ga-wisp-stuck start-pending 2400 > "$S/list.1"; echo 1 > "$S/peek_rc"
do_sweep
eq "B: a genuinely stuck start-pending IS still closed (safety net kept)" "$(closed_ids)" "ga-wisp-stuck"

echo "  scenario C: snapshot says asleep/900s, but by the re-read the controller made it creating (TOCTOU)"
run_sweep C; session_json ga-wisp-race asleep 900 > "$S/list.1"; session_json ga-wisp-race creating 900 > "$S/list.2"; echo 1 > "$S/peek_rc"
do_sweep
eq "C: moved to creating between snapshot and close → NOT closed" "$(closed_ids)" ""

echo "  scenario D: re-read fails (second 'session list' errors) → fail-safe"
run_sweep D; session_json ga-wisp-unread asleep 900 > "$S/list.1"; echo 1 > "$S/peek_rc"; : > "$S/list.fail.2"
do_sweep
eq "D: unreadable re-read → NOT closed (never close on incomplete info)" "$(closed_ids)" ""

echo "  scenario E: NON-REGRESSION — asleep 900s, peek gone, state unchanged on re-read"
run_sweep E; session_json ga-wisp-dead asleep 900 > "$S/list.1"; echo 1 > "$S/peek_rc"
do_sweep
eq "E: a genuinely dead (asleep, old, peek gone) reviewer IS still closed" "$(closed_ids)" "ga-wisp-dead"
has "$T9/orphan.log" 'closed dead gate-reviewer ga-wisp-dead' "E: the close is still logged"

echo "  scenario F: NON-REGRESSION — alive (peek ok) is never closed, whatever the state"
run_sweep F; session_json ga-wisp-alive asleep 900 > "$S/list.1"; echo 0 > "$S/peek_rc"
do_sweep
eq "F: peek exit 0 → NOT closed" "$(closed_ids)" ""

echo "── 10. drift-guard: the ga-2hd02v.1.23 wiring is still in the script under test ──"
has "$SCRIPT" 'GATE_REVIEWER_ORPHAN_CLEAR_START_PENDING_MIN_AGE_SECS:-1500' "start-pending floor is configurable and defaults to 1500s (>> the 2-10 min wake queue)"
has "$SCRIPT" 'keep_start_pending\) +kept_start_pending=' "sweep loop skips (and counts) start-pending below its floor"
has "$SCRIPT" 'orphan_clear_decision "\$state" "\$age" "\$MIN_AGE_SECS" "\$START_PENDING_MIN_AGE_SECS"' "sweep loop passes the start-pending floor to the decision function"
has "$SCRIPT" 'orphan_clear_recheck_decision "\$state" "\$cur_state"' "sweep loop gates the close on the re-read state"
# The re-read must sit BETWEEN the peek and the close, otherwise it protects nothing.
_ln_peek=$(grep -n 'gc session peek "\$sid"' "$SCRIPT" | head -1 | cut -d: -f1)
_ln_reread=$(grep -n 'cur_state=\$(orphan_clear_current_state' "$SCRIPT" | head -1 | cut -d: -f1)
_ln_close=$(grep -n 'if gc session close "\$sid"' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$_ln_peek" ] && [ -n "$_ln_reread" ] && [ -n "$_ln_close" ] \
   && [ "$_ln_peek" -lt "$_ln_reread" ] && [ "$_ln_reread" -lt "$_ln_close" ]; then
  ok "order is peek (line $_ln_peek) → re-read (line $_ln_reread) → close (line $_ln_close)"
else
  bad "order peek → re-read → close broken or missing (peek=[$_ln_peek] reread=[$_ln_reread] close=[$_ln_close])"
fi

echo ""
echo "──────────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  SELFTEST FAILED"
  exit 1
fi
echo "  SELFTEST OK"
exit 0
