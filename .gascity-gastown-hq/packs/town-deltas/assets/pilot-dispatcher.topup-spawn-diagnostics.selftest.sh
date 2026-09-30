#!/usr/bin/env bash
# pilot-dispatcher.topup-spawn-diagnostics.selftest.sh — unit tests for
# _pilot_topup_spawn (ga-kmm6rb).
#
# Bug ga-kmm6rb: the pool top-up spawn call in _pilot_pool_topup discarded
# BOTH stdout and stderr via `>/dev/null 2>&1`, and the exit code was only
# ever reported as a generic "pool top-up spawn failed ... — will retry next
# sweep" with no diagnostic content. Measured live: 3/3 top-up spawn attempts
# failed since the ga-swnsg3 merge (17:13, 17:37, 18:00), all equally opaque.
# The dispatch-path spawn (dispatch_one(), lines ~9829/9884) uses the
# structurally identical `gc --city ... session new <pool> --no-attach
# --title-hint ... >/dev/null 2>&1` shape and succeeded in the same window
# (17:16:09) — ruling out an argument/environment difference between the two
# paths (ACEITE #2's third hypothesis). The Mayor's own manual reproduction
# of this exact command hit a transient Dolt "invalid connection" under high
# CPU and succeeded on a second try — the remaining, corroborated hypothesis
# (ACEITE #2's first branch: "if it's a transient Dolt error, retry short
# within the same sweep").
#
# The fix: extract the spawn call into _pilot_topup_spawn(pool, pending),
# which captures real stderr+exit code (never >/dev/null again on this path)
# and logs it via `warn` on failure, retrying once immediately before giving
# up for this sweep. Whether or not the retry hypothesis is exactly right,
# the NEXT live failure now leaves a diagnosable log line instead of another
# silent "failed, will retry next sweep" — this selftest locks in that
# observability guarantee structurally (Scenario D/E), not just the retry
# behavior (Scenarios A-C).
#
# This harness extracts the function verbatim from the live dispatcher, same
# awk-extraction + fake gc/log/warn shell-function pattern
# pilot-dispatcher.sling-unsuppress-on-failure.selftest.sh already uses.
#
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"   # override: point at a pre-fix copy to see the newest scenarios RED

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# ── Extract the function verbatim from the live file ────────────────────────
SPAWN_FN="$(awk '/^_pilot_topup_spawn\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
if [ -z "$SPAWN_FN" ]; then
  echo "FATAL: _pilot_topup_spawn() not found in $DISPATCHER (ga-kmm6rb fix missing, or extraction pattern drifted)" >&2
  exit 2
fi

# ga-6hr8p7: _pilot_topup_spawn now calls two small helpers (the per-sweep "one slow spawn" bookkeeping). They are
# extracted with it — without them the copy would hit "command not found" and pass by accident. Empty on a
# pre-fix dispatcher, which is fine: the scenarios that need them are then the RED.
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
HELPER_FNS="$(fn_src _pilot_slow_spawn_budget_spent)
$(fn_src _pilot_note_spawn_timing)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-topup-spawn-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
CALLS="$WORK/calls.log"
mkdir -p "$WORK/bin"
# ga-ck3sz7: the spawn runs on a PATH with NO real gc/bd (selftest-sandbox-path.lib.sh): the stub `gc` in
# $WORK/bin is the only one it can find. `_pilot_topup_spawn` runs `gc session new` — if the stub vanished under
# it, a real gc further down $PATH would open a REAL session; here that is "command not found" instead.
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$WORK" timeout jq || exit 2   # the spawn is bounded by a real `timeout` (jq: Scenario M's predicate); gc is the stub below

# run_spawn <pool> <pending> <gc_script_body>
# gc_script_body is shell code (a script BODY, using `exit` not `return`)
# defining how the fake `gc` behaves on each call; it can reference `$n`
# (the 1-indexed call count, already computed by the wrapper) to vary
# behavior across calls (e.g. fail once then succeed).
#
# _pilot_topup_spawn calls `timeout <secs> gc ...` directly (matching the
# real production code's own convention — a literal command name, not an
# indirection variable like crew-liveness-probe.sh's $GC). `timeout` execs
# its argument as a REAL external process — a bash function named `gc`
# defined in this script is invisible to it (functions do not survive
# exec()). So the fake `gc` must be a real executable file found via PATH,
# not a shell function — same requirement crew-liveness-probe.sh's own
# selftest solves by writing a real $TMP/gc script and pointing an
# indirection variable at it; here the call site is a hardcoded literal
# `gc`, so PATH itself is what gets redirected instead.
run_spawn() {
  : > "$CALLS"
  : > "$WORK/gc_call_count"
  local _rs_pool="$1" _rs_pending="$2" _rs_gc_body="$3"
  cat > "$WORK/bin/gc" <<GCSCRIPT
#!/usr/bin/env bash
n=\$(cat "$WORK/gc_call_count" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "$WORK/gc_call_count"
printf 'gc\t%s\n' "\$*" >> "$CALLS"
$_rs_gc_body
GCSCRIPT
  chmod +x "$WORK/bin/gc"
  (
    PATH="$SANDBOX_PATH"
    GC_CITY="test-city"
    PILOT_SPAWN_TIMEOUT_SECS="${RS_TIMEOUT:-5}"   # ga-6hr8p7: RS_TIMEOUT=<s> shortens the budget for the real-kill scenario
    PILOT_TOPUP_RETRY_DELAY_SECS=0
    log()  { printf 'log\t%s\n'  "$*" >> "$CALLS"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$CALLS"; }
    eval "$HELPER_FNS"
    eval "$SPAWN_FN"
    # ga-6hr8p7: RS_PRESET_SLOW=1 → "a spawn earlier THIS sweep was slow" before the call, as in a real sweep.
    [ -z "${RS_PRESET_SLOW:-}" ] || _PILOT_SLOW_SPAWN_SEEN=1
    _pilot_topup_spawn "$_rs_pool" "$_rs_pending"
    echo "RC=$?" >> "$CALLS"
    echo "SLOW=${_PILOT_SLOW_SPAWN_SEEN:-0}" >> "$CALLS"
  )
}

has_call() { grep -qF -- "$1" "$CALLS" 2>/dev/null; }
gc_calls() { local _gn; _gn=$(cat "$WORK/gc_call_count" 2>/dev/null); echo "${_gn:-0}"; }   # empty file (no gc call was made) reads as 0, not ""

echo "pilot-dispatcher.topup-spawn-diagnostics.selftest — real stderr capture + single retry (ga-kmm6rb)"

# ── Scenario A: first attempt succeeds — no retry, no failure log ──────────
echo "Scenario A: first spawn attempt succeeds — returns 0, exactly 1 gc call, no failure logged"
run_spawn "wa-worker" "wa-abc12" 'echo "spawned ok" >&2; exit 0'
if has_call "RC=0" && [ "$(gc_calls)" -eq 1 ]; then
  ok "success on first attempt — RC=0, exactly 1 gc call (no retry attempted)"
else
  bad "expected RC=0 with exactly 1 gc call, got $(gc_calls) calls (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if grep -q '^warn\t' "$CALLS"; then
  bad "REGRESSION: warned on a clean first-attempt success"
else
  ok "no warn logged on clean success"
fi

# ── Scenario B: first attempt fails, retry succeeds ─────────────────────────
echo "Scenario B: first attempt fails (transient), retry succeeds — RC=0, exactly 2 gc calls, real stderr logged for attempt 1"
run_spawn "wa-worker" "wa-def34" '
  if [ "$n" -eq 1 ]; then echo "listing sessions: search wisps (merge): search wisps: invalid connection" >&2; exit 1; fi
  exit 0
'
if has_call "RC=0" && [ "$(gc_calls)" -eq 2 ]; then
  ok "retry succeeded — RC=0, exactly 2 gc calls (1 failure + 1 retry)"
else
  bad "expected RC=0 with exactly 2 gc calls, got $(gc_calls) calls (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if has_call "invalid connection"; then
  ok "the REAL captured stderr text from attempt 1 appears in the log (ACEITE #1 — no more 2>/dev/null blindness)"
else
  bad "attempt 1's real stderr was not captured/logged (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if grep -q '^log\t.*retry' "$CALLS" || grep -qi 'retry' "$CALLS"; then
  ok "a retry-succeeded line was logged"
else
  bad "no indication the retry succeeded was logged"
fi

# ── Scenario C: both attempts fail — RC=1, both failures logged distinctly ─
echo "Scenario C: both attempts fail — RC=1, exactly 2 gc calls, BOTH failures' real stderr logged, final give-up message present"
run_spawn "ps-worker" "ps-ghi56" '
  echo "attempt-$n: connection refused" >&2
  exit 1
'
if has_call "RC=1" && [ "$(gc_calls)" -eq 2 ]; then
  ok "both attempts failed — RC=1, exactly 2 gc calls (no infinite retry loop)"
else
  bad "expected RC=1 with exactly 2 gc calls, got $(gc_calls) calls (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if has_call "attempt-1: connection refused" && has_call "attempt-2: connection refused"; then
  ok "BOTH attempts' real stderr text was captured and logged distinctly"
else
  bad "did not capture/log both attempts' distinct stderr text (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if grep -qi "giving up\|will retry next sweep" "$CALLS"; then
  ok "a final give-up-this-sweep message was logged when both attempts failed"
else
  bad "no give-up/retry-next-sweep message logged after both attempts failed"
fi

# ── Scenario D: no stderr output at all on failure — logs an explicit
#    'no stderr captured' marker rather than an empty/blank message that
#    looks identical to 'nothing went wrong' ─────────────────────────────
echo "Scenario D: failing gc call produces NO stderr at all — failure is still logged with an explicit empty-output marker, not silently"
run_spawn "wa-worker" "wa-jkl78" 'exit 1'
if has_call "RC=1"; then
  ok "silent (no-stderr) failure still returns RC=1"
else
  bad "expected RC=1 for a silent failure"
fi
if grep -qi "no stderr captured\|<empty>\|(no output)" "$CALLS"; then
  ok "a silent failure (no stderr text) is logged with an explicit 'nothing captured' marker, not blank"
else
  bad "a silent failure produced no distinguishing marker — 'no stderr' could be misread as 'no failure' (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi

# ── Scenario E: drift-guard — the old >/dev/null 2>&1 spawn call is GONE
#    from _pilot_pool_topup, replaced by a call to the new helper ──────────
echo "Scenario E: drift-guard — _pilot_pool_topup calls _pilot_topup_spawn instead of the old blind >/dev/null 2>&1 inline call"
if grep -q '_pilot_topup_spawn "\$_pool" "\$_pending"' "$DISPATCHER"; then
  ok "_pilot_pool_topup calls the new _pilot_topup_spawn helper"
else
  bad "REGRESSION: _pilot_pool_topup does not call _pilot_topup_spawn — ga-kmm6rb fix may have been reverted or never wired in"
fi
# The OLD inline pattern used --title-hint "pool top-up: $_pending" directly
# followed by >/dev/null 2>&1 on the SAME logical statement. Confirm that
# specific blind-discard shape no longer exists anywhere in the file for the
# "pool top-up: " title-hint text specifically (the dispatch-path spawns at
# ~L9829/9884 use a DIFFERENT title-hint — "build $STORY_ID: ..." — and are
# explicitly out of scope for this bead; this check must not flag those).
if grep -B1 -- '--title-hint "pool top-up: \$_pending"' "$DISPATCHER" | grep '>/dev/null 2>&1' >/dev/null; then
  bad "REGRESSION: the pool-top-up title-hint call site still discards stderr via >/dev/null 2>&1 — ga-kmm6rb's ACEITE #1 is not satisfied"
else
  ok "the pool-top-up title-hint call site no longer blindly discards stderr"
fi

# ── Scenario F: runtime reachability — _pilot_topup_spawn is defined BEFORE
#    _pilot_pool_topup (bash has no function hoisting; _pilot_pool_topup
#    calls it internally, so definition order only needs to precede
#    _pilot_pool_topup's OWN top-level call site, not this internal call —
#    but defining it first, adjacent to its only caller, is this file's own
#    established convention (see _topup_rig_pending immediately above
#    _pilot_pool_topup) and keeps the dependency direction unambiguous ──────
echo "Scenario F: _pilot_topup_spawn is defined before _pilot_pool_topup calls it"
SPAWN_DEF_LINE=$(grep -n '^_pilot_topup_spawn() {' "$DISPATCHER" | head -1 | cut -d: -f1)
TOPUP_DEF_LINE=$(grep -n '^_pilot_pool_topup() {' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -z "$SPAWN_DEF_LINE" ] || [ -z "$TOPUP_DEF_LINE" ]; then
  bad "could not locate one of: spawn def ($SPAWN_DEF_LINE), topup def ($TOPUP_DEF_LINE)"
elif [ "$SPAWN_DEF_LINE" -lt "$TOPUP_DEF_LINE" ]; then
  ok "_pilot_topup_spawn defined at line $SPAWN_DEF_LINE, before _pilot_pool_topup at line $TOPUP_DEF_LINE"
else
  bad "_pilot_topup_spawn defined at line $SPAWN_DEF_LINE, AFTER _pilot_pool_topup at line $TOPUP_DEF_LINE — fine at runtime (bash resolves calls made from within a function body at call time, not definition time) but breaks this file's own established convention of defining a helper immediately above its sole caller"
fi

# ── Scenario G: drift-guard — a pause sits between attempt 1 and the retry,
#    configurable via PILOT_TOPUP_RETRY_DELAY_SECS (an instant back-to-back
#    retry has no better odds than the original attempt against the
#    corroborating "transient Dolt load" hypothesis, which cleared only by
#    the time of a SEPARATELY-typed second command) ─────────────────────────
echo "Scenario G: drift-guard — a configurable pause separates attempt 1 from the retry"
_SPAWN_FN_BODY_LINES=$(printf '%s\n' "$SPAWN_FN")
if printf '%s\n' "$_SPAWN_FN_BODY_LINES" | grep 'sleep "\${PILOT_TOPUP_RETRY_DELAY_SECS:-' >/dev/null; then
  ok "a configurable sleep (PILOT_TOPUP_RETRY_DELAY_SECS) sits before the retry attempt"
else
  bad "REGRESSION: no configurable pause found before the retry — an instant back-to-back retry may not out-run the same transient Dolt saturation the original attempt hit"
fi
# Behavioral companion: with the delay ZEROED (as every other scenario in
# this file already does via run_spawn's subshell), Scenario B's own timing
# already proves the delay doesn't block success — this scenario only
# guards that the KNOB exists and is wired, not its runtime effect (which
# would require a real clock measurement this hermetic harness deliberately
# avoids, matching PILOT_SPAWN_TIMEOUT_SECS's own test-seam treatment above).

# ── ga-6hr8p7: ONE slow spawn per sweep ──────────────────────────────────────
# `gc session new` needs 38 s by hand at load ~40 and 60+ s at load 50-80; the 60 s kill landed before the CLI
# finished on every attempt (134x in 12 h). The budget is now 150 s — and a sweep gets ONE slow spawn, so the longer
# budget cannot stack N x 150 s. These scenarios drive the REAL `timeout` (run_spawn's sandbox has it), so a
# kill is a real exit 124, not a stub that merely exits 124. Sweep-level (two pools) is in pool-cap-fail-closed T9-T13.

echo "Scenario H: a spawn earlier THIS sweep was slow — the top-up DEFERS: no gc call at all, RC=1, announced"
RS_PRESET_SLOW=1 run_spawn "wa-worker" "wa-slow1" 'exit 0'
if has_call "RC=1" && [ "$(gc_calls)" -eq 0 ]; then
  ok "budget spent → RC=1 with ZERO gc calls (the second slow spawn is never started)"
else
  bad "expected RC=1 and 0 gc calls once the sweep's slow spawn is spent, got $(gc_calls) call(s) (dump: $(tr '\n' '|' < "$CALLS"))"
fi
if has_call "DEFERRED"; then
  ok "the deferral is logged (a skipped top-up is visible, not silent)"
else
  bad "no DEFERRED line — a skipped top-up would be invisible in the pilot log"
fi

echo "Scenario I: a REAL timeout kill (exit 124) spends the sweep's slow spawn — flag set, still no blind retry (ga-oa004t)"
# 1 s budget against a 4 s stub; `exec` so the kill lands on the sleeping process itself (an orphaned sleep would
# keep the stderr-capture pipe open and hold the call until it ends).
RS_TIMEOUT=1 run_spawn "wa-worker" "wa-kill1" 'exec sleep 4'
if has_call "RC=1" && [ "$(gc_calls)" -eq 1 ] && has_call "SLOW=1"; then
  ok "killed at the budget → RC=1, ONE attempt (no blind retry), and the slow-spawn flag is SET for the rest of the sweep"
else
  bad "expected RC=1, 1 gc call, SLOW=1 after a real timeout kill; got $(gc_calls) call(s) (dump: $(tr '\n' '|' < "$CALLS"))"
fi

echo "Scenario J: a SLOW spawn that SUCCEEDS (3 s vs a 2 s threshold) also sets the flag; an instant one does not (control)"
# Threshold 2 / stub 3 s, not 1 / 2 s: bash's $SECONDS ticks on wall-clock second boundaries, so an INSTANT spawn that
# straddles a boundary reads as 1 s elapsed — a 1 s threshold would make the control flaky. A reading is off by <1 s
# either way, so 3 s always reads >= 2 and an instant spawn always reads <= 1.
( PILOT_SLOW_SPAWN_SECS=2; run_spawn "wa-worker" "wa-slow2" 'sleep 3; exit 0' )
if has_call "RC=0" && has_call "SLOW=1"; then
  ok "slow success → RC=0 and the flag is set (a success at 100 s blocks the sweep as long as a timeout does)"
else
  bad "slow success did not set the flag (dump: $(tr '\n' '|' < "$CALLS"))"
fi
( PILOT_SLOW_SPAWN_SECS=2; run_spawn "wa-worker" "wa-fast1" 'exit 0' )
if has_call "RC=0" && has_call "SLOW=0"; then
  ok "control: an instant success leaves the flag CLEAR (the cap does not over-block healthy spawns)"
else
  bad "control failed: a fast success set the flag or did not return 0 (dump: $(tr '\n' '|' < "$CALLS"))"
fi

echo "Scenario K: a spawn that FAILS after being slow is NOT retried (a retry would be a second slow spawn)"
( PILOT_SLOW_SPAWN_SECS=1; run_spawn "wa-worker" "wa-slow3" 'sleep 2; echo "late failure" >&2; exit 1' )
if has_call "RC=1" && [ "$(gc_calls)" -eq 1 ] && has_call "NOT retrying"; then
  ok "slow failure → ONE gc call, 'NOT retrying' logged (Scenario C keeps the retry for fast failures)"
else
  bad "expected 1 gc call and a 'NOT retrying' line after a slow failure, got $(gc_calls) call(s) (dump: $(tr '\n' '|' < "$CALLS"))"
fi
has_call "late failure" && ok "the slow failure's real stderr is still captured and logged" \
  || bad "the slow failure's stderr text was lost"

echo "Scenario L: drift-guard — no spawn call site keeps the old 60 s literal; all four use the 150 s budget"
_old60=$(grep -c 'timeout "\${PILOT_SPAWN_TIMEOUT_SECS:-60}"' "$DISPATCHER" 2>/dev/null); _old60="${_old60:-0}"
_new150=$(grep -c 'timeout "\${PILOT_SPAWN_TIMEOUT_SECS:-150}"' "$DISPATCHER" 2>/dev/null); _new150="${_new150:-0}"
if [ "$_old60" = "0" ] && [ "$_new150" = "4" ]; then
  ok "4 spawn calls (2 in _pilot_topup_spawn + wa/ps arms of dispatch_one) on the 150 s default, none on 60 s"
else
  bad "spawn budget drift: $_old60 call(s) still on the 60 s default, $_new150 on 150 s (want 0 and 4) — a spawn site that kept 60 s is killed before it finishes under load"
fi

echo "Scenario M: _pilot_slow_spawn_deferred_for — the PRE-claim twin defers ONLY a candidate already committed to a pool that would spawn, and only once the budget is spent"
# dispatch_lane() asks this before claiming a candidate. Too eager and a slow pool spawn starves CREW dispatches;
# too shy and every remaining candidate is claimed → stamped → released (~5 Dolt writes each) on a box that is slow
# because of load. Each case prints "defer" or "run"; on a pre-fix dispatcher the function is absent → always "run".
DEFER_FN="$(fn_src _pilot_slow_spawn_deferred_for)"
defer_case() { # <budget-spent 0|1> <gc.routed_to value> [<shell assignment(s) to eval first>]
  (
    PATH="$SANDBOX_PATH"
    eval "$HELPER_FNS"; eval "$DEFER_FN"
    [ "$1" != "1" ] || _PILOT_SLOW_SPAWN_SEEN=1
    [ -z "${3:-}" ] || eval "$3"
    if _pilot_slow_spawn_deferred_for "{\"id\":\"x\",\"metadata\":{\"gc.routed_to\":\"$2\"}}" 2>/dev/null; then echo defer; else echo run; fi
  )
}
m_expect() { # <expected> <description> <defer_case args…>
  local _want="$1" _desc="$2" _got; shift 2
  _got="$(defer_case "$@")"
  if [ "$_got" = "$_want" ]; then ok "M: $_desc → $_got"; else bad "M: $_desc → $_got (want $_want)"; fi
}
m_expect defer "budget spent + routed to wa-worker"                          1 wa-worker
m_expect defer "budget spent + routed to ps-worker"                          1 ps-worker
m_expect run   "budget NOT spent + routed to wa-worker (nothing is slow yet)" 0 wa-worker
m_expect run   "budget spent + not routed yet (decided in the pool arm, after the claim)" 1 ""
m_expect run   "budget spent + routed to a CREW (a slow pool spawn must not block crew dispatch)" 1 batista-wa
m_expect run   "budget spent + wa-worker + PILOT_SPAWN_WA_WORKER=0 (nudge-only debug mode never spawns)" 1 wa-worker 'PILOT_SPAWN_WA_WORKER=0'
m_expect run   "budget spent + ps-worker + PILOT_SPAWN_PS_WORKER=0" 1 ps-worker 'PILOT_SPAWN_PS_WORKER=0'

echo "Scenario N: _pilot_note_spawn_timing — a duration we cannot read is UNKNOWN, not 'instant' (three states: fast / slow / can't tell)"
# The third state again: "no usable start time" must not collapse into the same verdict as "it was quick".
# For a spawn gate the inert answer is to assume slow — defer the rest of the sweep — never to assume fast.
note_case() { # <rc> <t0-expression> [<PILOT_SLOW_SPAWN_SECS>] → prints the flag after the call
  (
    PATH="$SANDBOX_PATH"
    eval "$HELPER_FNS"
    SECONDS=1000   # a fresh subshell's clock is tiny; "started N s ago" must not go negative
    [ -z "${3:-}" ] || PILOT_SLOW_SPAWN_SECS="$3"
    eval "_t0val=$2"
    _pilot_note_spawn_timing "$1" "$_t0val" 2>/dev/null
    echo "${_PILOT_SLOW_SPAWN_SEEN:-0}"
  )
}
n_expect() { # <expected flag> <description> <note_case args…>
  local _want="$1" _desc="$2" _got; shift 2
  _got="$(note_case "$@")"
  if [ "$_got" = "$_want" ]; then ok "N: $_desc → flag=$_got"; else bad "N: $_desc → flag=$_got (want $_want)"; fi
}
n_expect 1 "start time MISSING (empty) counts as slow"                                  0 "''"
n_expect 1 "start time not a number counts as slow"                                     0 "'abc'"
n_expect 0 "control: a spawn that just started and exited 0 is fast (threshold 60)"      0 '$SECONDS'
n_expect 1 "an exit 124 is slow whatever the clock says"                                 124 '$SECONDS'
n_expect 1 "known duration >= threshold is slow (started 100 s ago, threshold 60)"       0 '$((SECONDS - 100))'
n_expect 0 "known duration < threshold is fast (started 10 s ago, threshold 60)"         0 '$((SECONDS - 10))'
n_expect 1 "a non-numeric PILOT_SLOW_SPAWN_SECS falls back to 60, not to 'never slow' (started 100 s ago)" 0 '$((SECONDS - 100))' 'oops'

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "pilot-dispatcher.topup-spawn-diagnostics.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
