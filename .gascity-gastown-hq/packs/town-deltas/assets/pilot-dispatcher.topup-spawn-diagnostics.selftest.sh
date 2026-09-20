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
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-topup-spawn-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
CALLS="$WORK/calls.log"
mkdir -p "$WORK/bin"

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
    PATH="$WORK/bin:$PATH"
    GC_CITY="test-city"
    PILOT_SPAWN_TIMEOUT_SECS=5
    PILOT_TOPUP_RETRY_DELAY_SECS=0
    log()  { printf 'log\t%s\n'  "$*" >> "$CALLS"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$CALLS"; }
    eval "$SPAWN_FN"
    _pilot_topup_spawn "$_rs_pool" "$_rs_pending"
    echo "RC=$?" >> "$CALLS"
  )
}

has_call() { grep -qF -- "$1" "$CALLS" 2>/dev/null; }
gc_calls() { cat "$WORK/gc_call_count" 2>/dev/null || echo 0; }

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

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "pilot-dispatcher.topup-spawn-diagnostics.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
