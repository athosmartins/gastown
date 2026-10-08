#!/usr/bin/env bash
# gate-spawn-transient-retry.selftest.sh — ga-2u38b mutation test.
#
# CASO (Mayor, 2026-08-06 08:2x): marker ga-wisp-sx4ahir, branch
# fix/ga-r7m8b-session-idle-json-crash. The gate dispatcher had already done
# ALL the expensive work for this run (auto-rebase, push, stale-base check,
# sizing, verdict-bead creation) when reviewer-spawn hit:
#   ERROR: Failed to spawn reviewer session 1 (ga-mzc3h). Aborting gate.
#     gc session new: listing sessions: search wisps (merge): search wisps:
#     invalid connection      <- Dolt/MySQL connection dropped mid-call
# The dispatcher treated this identically to a BROKEN template or session-cap
# deadlock: gate-status:dispatching -> gate-status:error. No sweep re-admits
# gate-status:error — a human had to flip it back by hand. "invalid
# connection" appeared 12 TIMES in the dispatcher log that sweep, each one
# discarding a fully-paid-for run, heaviest exactly when Dolt is under load
# (403% CPU that morning) — the worst possible time to throw work away
# (root-class:transient-infra-is-terminal).
#
# FIX (three layers, quality-gate-dispatcher.sh):
#   1. is_transient_spawn_error(): pure classifier — recognizes the observed
#      connection-drop signature family (invalid connection / read tcp /
#      broken pipe / connection reset / dial tcp / connection refused / i/o
#      timeout). Deliberately does NOT match bare "EOF" or "timeout" — those
#      are common substrings of unrelated failures too, and a false-transient
#      classification would silently mask a real broken-spawn outage behind
#      endless auto-retries instead of ever reaching gate-status:error.
#   2. In-process retry loop (spawn-retry-loop, extracted below): a short,
#      bounded, backed-off in-process re-attempt of `gc session new` BEFORE
#      the run gives up at all — the rebase/push/sizing/verdict-bead work is
#      already paid for, so a blip that clears in a few seconds should never
#      touch the marker's gate-status.
#   3. gate_spawn_failure_requeue_or_error(): if the run still can't spawn,
#      decides AND applies the marker's fate. Transient + under
#      GATE_SPAWN_TRANSIENT_MAX_ATTEMPTS -> gate-status:ready (auto
#      re-admitted by the guard) with a verified gate:spawn-fail-count:N
#      counter. Non-transient, OR cap exhausted, OR the counter write itself
#      can't be verified (ga-6dp9 falsify-the-write pattern) -> falls through
#      to the UNCHANGED gate-status:error path.
#
# ACEITE (from the bug): a test that injects 'invalid connection' and proves
# the marker ends at gate-status:ready with attempts=1 is not sufficient by
# itself — a non-transient error must still reach gate-status:error, or the
# test doesn't prove the distinction exists. Both are covered below.
#
# This harness sources the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test is_transient_spawn_error (pure) and
# gate_spawn_failure_requeue_or_error (bd-backed, driven by in-shell mocks —
# NO live Dolt/gc/launchd), then extracts the spawn-retry-loop block verbatim
# (genuine live extraction, not a hand-copied mirror — same technique as
# gate-q8tj7p-queue-order.selftest.sh) to prove the in-process retry actually
# recovers from a one-shot blip. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

echo "== gate-spawn-transient-retry.selftest (ga-2u38b) =="

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

for fn in is_transient_spawn_error read_spawn_fail_count gate_spawn_failure_requeue_or_error gate_rebase_attempt_advanced; do
  type "$fn" >/dev/null 2>&1 \
    || { echo "FATAL: $fn not defined by dispatcher (ga-2u38b fix missing?)"; exit 1; }
done

# gate-fix-4 lesson (ga-kgtiw, applied proactively here): log/warn/err are
# DELIBERATELY NOT stubbed to pure no-ops. gate_spawn_failure_requeue_or_error
# is documented MUTE-BY-CONSTRUCTION (zero log/warn/err calls) specifically
# because every real call site captures its stdout via $(...) — this script's
# own log/warn/err write via plain `echo` (not `>&2`), so a stray call would
# splice straight into the captured "ready"/"error" token. Emitting a
# distinctive, unmistakable, non-empty marker on every call means a future
# regression that adds such a call corrupts the token and fails the EXACT-match
# eq() assertions below — a silent no-op mock could never catch that.
log()  { printf 'LOGCALL:log:%s\n' "$*"; }
warn() { printf 'LOGCALL:warn:%s\n' "$*"; }
err()  { printf 'LOGCALL:err:%s\n' "$*"; }

# ── 1. is_transient_spawn_error — pure classifier ─────────────────────────────
echo "── 1. is_transient_spawn_error (pure) ──"
eq "live incident string (08:10:23, ga-wisp-sx4ahir) → transient" \
  "$(is_transient_spawn_error 'gc session new: listing sessions: search wisps (merge): search wisps: invalid connection')" "1"
eq "read tcp → transient" \
  "$(is_transient_spawn_error 'read tcp 127.0.0.1:52756->127.0.0.1:44012: read: connection reset by peer')" "1"
eq "broken pipe → transient" \
  "$(is_transient_spawn_error 'write: broken pipe')" "1"
eq "dial tcp + connection refused → transient" \
  "$(is_transient_spawn_error 'dial tcp 127.0.0.1:52756: connect: connection refused')" "1"
eq "i/o timeout → transient" \
  "$(is_transient_spawn_error 'read tcp 127.0.0.1:52756: i/o timeout')" "1"
eq "native_store_unavailable WARN only, no mysql text (ga-jeicm, ga-oj9pc incident 2026-08-07 19:09-11) → transient" \
  "$(is_transient_spawn_error '2026/08/07 19:09:58 WARN native_store_unavailable gate=version_compat reason="bd version differs from linked beads library version" scope=/Users/athos/gt/.gascity-gastown-hq')" "1"
eq "empty spawn_err → NOT transient (no output means no evidence of a connection blip)" \
  "$(is_transient_spawn_error '')" "0"
eq "unknown template (ga-mzc3h class) → NOT transient" \
  "$(is_transient_spawn_error "template 'gate-reviewer' not found")" "0"
eq "session cap deadlock → NOT transient" \
  "$(is_transient_spawn_error 'session cap exceeded for template gate-reviewer')" "0"
eq "bare 'EOF' → NOT transient (deliberately excluded: too common a substring of unrelated failures)" \
  "$(is_transient_spawn_error 'unexpected EOF')" "0"

# ── 2. read_spawn_fail_count — label-counter reader (mock bd show) ───────────
echo "── 2. read_spawn_fail_count (mock bd show) ──"
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *) : ;;
  esac
  return 0
}
MOCK_SHOW_JSON='[{"id":"m1","labels":["type:quality-gate-marker","gate-status:dispatching"]}]'
eq "no gate:spawn-fail-count label → 0" "$(read_spawn_fail_count m1)" "0"
MOCK_SHOW_JSON='[{"id":"m1","labels":["gate-status:dispatching","gate:spawn-fail-count:2"]}]'
eq "gate:spawn-fail-count:2 present → 2" "$(read_spawn_fail_count m1)" "2"
MOCK_SHOW_JSON='[{"id":"m1","labels":["gate:spawn-fail-count:1","gate:spawn-fail-count:2"]}]'
eq "two stale counter values present → highest wins (2)" "$(read_spawn_fail_count m1)" "2"

# ── 3. gate_spawn_failure_requeue_or_error — decision + writes (mock bd) ─────
echo "── 3. gate_spawn_failure_requeue_or_error (mock bd, no live Dolt) ──"

# gate-fix-2 subtlety (borrowed from gate-marker-status-selfheal.selftest.sh,
# ga-kgtiw): `$(gate_spawn_failure_requeue_or_error ...)` forks a SUBSHELL in
# bash, so any MOCK_* variable mutation made by the mocked bd() during that
# call is invisible once the subshell exits — the exact kind of
# error/empty-conflation this bug is about, one layer up in the harness
# itself. _capture_out runs the call directly (stdout to a file, not a
# substitution) so the mocked call executes in THIS shell and its side
# effects survive.
_capture_out() {
  local __tmp
  __tmp=$(mktemp)
  "$@" >"$__tmp" && CAPTURED_RC=0 || CAPTURED_RC=$?
  CAPTURED=$(cat "$__tmp")
  rm -f "$__tmp"
}

# (a) THE ACEITE CASE: transient error, marker has no prior spawn-fail-count
# label -> "ready", attempt counter lands at exactly 1, gate-status:ready
# written, and — the other half of the ACEITE — gate-status:error is NEVER
# written on this path. The mock is STATEFUL (gate-fix-4 lesson): a real
# `bd label add` would change what a subsequent `bd show` returns, and this
# function re-reads after its own write to verify it (ga-6dp9 falsify-the-
# write pattern) — a mock that never updates MOCK_SHOW_JSON would make this
# successful requeue misread as an unverified one.
MOCK_SHOW_JSON='[{"id":"ga-wisp-sx4ahir","labels":["type:quality-gate-marker","gate-status:dispatching"]}]'
MOCK_LABEL_ADD_CALLS=""; MOCK_LABEL_REMOVE_CALLS=""; MOCK_COMMENT_CALLS=""
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *" label add "*)
      MOCK_LABEL_ADD_CALLS="$MOCK_LABEL_ADD_CALLS|$*"
      case " $* " in
        *"gate:spawn-fail-count:1"*) MOCK_SHOW_JSON='[{"id":"ga-wisp-sx4ahir","labels":["gate:spawn-fail-count:1"]}]' ;;
      esac
      ;;
    *" label remove "*) MOCK_LABEL_REMOVE_CALLS="$MOCK_LABEL_REMOVE_CALLS|$*" ;;
    *" comment "*)      MOCK_COMMENT_CALLS="$MOCK_COMMENT_CALLS|$*" ;;
    *) : ;;
  esac
  return 0
}
_capture_out gate_spawn_failure_requeue_or_error "ga-wisp-sx4ahir" \
  "gc session new: listing sessions: search wisps (merge): search wisps: invalid connection"
eq "(a) transient, attempt 1/N → returns 'ready'" "$CAPTURED" "ready"
case "$MOCK_LABEL_ADD_CALLS" in
  *"label add ga-wisp-sx4ahir gate:spawn-fail-count:1"*) ok "(a) attempt counter written as gate:spawn-fail-count:1 (attempts=1, matches ACEITE)" ;;
  *) bad "(a) expected gate:spawn-fail-count:1 label add, got: $MOCK_LABEL_ADD_CALLS" ;;
esac
case "$MOCK_LABEL_ADD_CALLS" in
  *"label add ga-wisp-sx4ahir gate-status:ready"*) ok "(a) marker requeued to gate-status:ready" ;;
  *) bad "(a) expected gate-status:ready label add, got: $MOCK_LABEL_ADD_CALLS" ;;
esac
case "$MOCK_LABEL_ADD_CALLS" in
  *"gate-status:error"*) bad "(a) gate-status:error must NEVER be written on the transient-under-cap path, got: $MOCK_LABEL_ADD_CALLS" ;;
  *) ok "(a) gate-status:error correctly NOT written (the other half of the ACEITE)" ;;
esac
case "$MOCK_COMMENT_CALLS" in
  *"ga-2u38b"*"attempt 1/"*) ok "(a) durable audit-trail comment left on the marker" ;;
  *) bad "(a) expected an audit comment naming the attempt, got: $MOCK_COMMENT_CALLS" ;;
esac

# (b) non-transient error → "error" IMMEDIATELY, zero bd writes at all. This
# is the half of the ACEITE a transient-only test cannot prove: the
# distinction must actually exist, not just the happy path.
MOCK_LABEL_ADD_CALLS=""; MOCK_LABEL_REMOVE_CALLS=""; MOCK_COMMENT_CALLS=""
_capture_out gate_spawn_failure_requeue_or_error "ga-wisp-other" "template 'gate-reviewer' not found"
eq "(b) non-transient (ga-mzc3h class) → returns 'error'" "$CAPTURED" "error"
eq "(b) non-transient → zero label writes (caller owns the gate-status:error write)" "$MOCK_LABEL_ADD_CALLS" ""
eq "(b) non-transient → zero comments (nothing to explain — this is the pre-existing behavior, unchanged)" "$MOCK_COMMENT_CALLS" ""

# (c) transient, but the retry budget is already spent (prev == MAX-1, so
# next == MAX) → "error", with an explicit giving-up comment; still no
# gate-status:ready write. Read the real default rather than hardcoding it,
# so this test can't silently drift from a future tuning of the knob.
MAX="$GATE_SPAWN_TRANSIENT_MAX_ATTEMPTS"
PREV=$((MAX - 1))
MOCK_SHOW_JSON="[{\"id\":\"ga-wisp-capped\",\"labels\":[\"gate:spawn-fail-count:${PREV}\"]}]"
MOCK_LABEL_ADD_CALLS=""; MOCK_LABEL_REMOVE_CALLS=""; MOCK_COMMENT_CALLS=""
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *" label add "*)    MOCK_LABEL_ADD_CALLS="$MOCK_LABEL_ADD_CALLS|$*" ;;
    *" label remove "*) MOCK_LABEL_REMOVE_CALLS="$MOCK_LABEL_REMOVE_CALLS|$*" ;;
    *" comment "*)      MOCK_COMMENT_CALLS="$MOCK_COMMENT_CALLS|$*" ;;
    *) : ;;
  esac
  return 0
}
_capture_out gate_spawn_failure_requeue_or_error "ga-wisp-capped" "invalid connection"
eq "(c) transient, attempt $MAX/$MAX (cap reached) → returns 'error'" "$CAPTURED" "error"
case "$MOCK_COMMENT_CALLS" in
  *"persisted for $MAX attempts"*"giving up"*) ok "(c) comment explains the cap was reached, not a silent drop" ;;
  *) bad "(c) expected a cap-exhausted comment, got: $MOCK_COMMENT_CALLS" ;;
esac
case "$MOCK_LABEL_ADD_CALLS" in
  *"gate-status:ready"*) bad "(c) must NOT requeue to ready once the cap is exhausted, got: $MOCK_LABEL_ADD_CALLS" ;;
  *) ok "(c) correctly did not requeue to gate-status:ready past the cap" ;;
esac

# (d) ga-6dp9 falsify-the-write pattern: the counter label ADD is accepted by
# the mock but does not actually change what a subsequent `bd show` returns
# (simulating the exact silently-lost-write class ga-6dp9/ga-kgtiw were filed
# for) → must NOT claim 'ready' on an unverified write; falls to 'error'
# instead of replaying "attempt 1/N" forever on a counter that cannot move.
MOCK_SHOW_JSON='[{"id":"ga-wisp-stuck","labels":["type:quality-gate-marker"]}]'
MOCK_LABEL_ADD_CALLS=""; MOCK_LABEL_REMOVE_CALLS=""; MOCK_COMMENT_CALLS=""
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;  # deliberately never updated by the label-add branch below
    *" label add "*)    MOCK_LABEL_ADD_CALLS="$MOCK_LABEL_ADD_CALLS|$*" ;;
    *" label remove "*) MOCK_LABEL_REMOVE_CALLS="$MOCK_LABEL_REMOVE_CALLS|$*" ;;
    *" comment "*)      MOCK_COMMENT_CALLS="$MOCK_COMMENT_CALLS|$*" ;;
    *) : ;;
  esac
  return 0
}
_capture_out gate_spawn_failure_requeue_or_error "ga-wisp-stuck" "invalid connection"
eq "(d) counter write does not verifiably land → returns 'error', not a false 'ready'" "$CAPTURED" "error"
case "$MOCK_COMMENT_CALLS" in
  *"did not verifiably land"*) ok "(d) comment honestly states the write could not be confirmed" ;;
  *) bad "(d) expected a write-not-verified comment, got: $MOCK_COMMENT_CALLS" ;;
esac
case "$MOCK_LABEL_ADD_CALLS" in
  *"gate-status:ready"*) bad "(d) must NOT claim gate-status:ready off an unverified counter write, got: $MOCK_LABEL_ADD_CALLS" ;;
  *) ok "(d) correctly withheld gate-status:ready pending an unverifiable write" ;;
esac

# (e) muteness regression guard: re-run the happy path (fresh stateful mock)
# and confirm the captured token is the EXACT string "ready" — not
# "LOGCALL:...\nready" or similar. An accidental log/warn/err call inside the
# function would corrupt this under the mocks installed at the top of this
# file (gate-fix-4 lesson). Plain $(...) is fine HERE specifically because
# only the function's own stdout token is being asserted on, not any mock
# call-count side effect — the exact case the subshell caveat above does not
# apply to.
MOCK_SHOW_JSON='[{"id":"ga-wisp-mute","labels":["type:quality-gate-marker"]}]'
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *" label add "*)
      case " $* " in
        *"gate:spawn-fail-count:1"*) MOCK_SHOW_JSON='[{"id":"ga-wisp-mute","labels":["gate:spawn-fail-count:1"]}]' ;;
      esac
      ;;
    *) : ;;
  esac
  return 0
}
RESULT=$(gate_spawn_failure_requeue_or_error "ga-wisp-mute" "invalid connection")
eq "(e) function is mute — captured token is exactly 'ready', no log/warn/err leakage" "$RESULT" "ready"

# ── 3b. gate_status_transition — mutual exclusion (ga-ia7m7) ─────────────────
echo "── 3b. gate_status_transition (mock bd, ga-ia7m7) ──"

# (a) marker carries TWO gate-status:* labels — the exact shape Mayor measured
# live on ga-c4pil (a stale 'queued' left by gate-recovery-watchdog's
# starvation self-heal, still present hours later when the spawn-failure path
# writes 'error'). Transition to error must remove BOTH pre-existing
# gate-status:* labels and add exactly one.
MOCK_SHOW_JSON='[{"id":"ga-c4pil-like","labels":["type:quality-gate-marker","gate-status:dispatching","gate-status:queued"]}]'
MOCK_LABEL_ADD_CALLS=""; MOCK_LABEL_REMOVE_CALLS=""
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *" label add "*)    MOCK_LABEL_ADD_CALLS="$MOCK_LABEL_ADD_CALLS|$*" ;;
    *" label remove "*) MOCK_LABEL_REMOVE_CALLS="$MOCK_LABEL_REMOVE_CALLS|$*" ;;
    *) : ;;
  esac
  return 0
}
gate_status_transition "ga-c4pil-like" "error"
case "$MOCK_LABEL_REMOVE_CALLS" in
  *"gate-status:dispatching"*) ok "(a) pre-existing gate-status:dispatching removed" ;;
  *) bad "(a) expected gate-status:dispatching to be removed, got: $MOCK_LABEL_REMOVE_CALLS" ;;
esac
case "$MOCK_LABEL_REMOVE_CALLS" in
  *"gate-status:queued"*) ok "(a) pre-existing STALE gate-status:queued removed (ga-c4pil incident shape)" ;;
  *) bad "(a) expected gate-status:queued to be removed, got: $MOCK_LABEL_REMOVE_CALLS" ;;
esac
case "$MOCK_LABEL_ADD_CALLS" in
  *"gate-status:error"*) ok "(a) gate-status:error added" ;;
  *) bad "(a) expected gate-status:error to be added, got: $MOCK_LABEL_ADD_CALLS" ;;
esac

# (b) marker's ONLY gate-status:* label already equals the target -> no
# redundant remove-then-readd churn on the target itself.
MOCK_SHOW_JSON='[{"id":"ga-already-ready","labels":["gate-status:ready"]}]'
MOCK_LABEL_ADD_CALLS=""; MOCK_LABEL_REMOVE_CALLS=""
gate_status_transition "ga-already-ready" "ready"
case "$MOCK_LABEL_REMOVE_CALLS" in
  *"gate-status:ready"*) bad "(b) must not remove the label that already matches the target, got: $MOCK_LABEL_REMOVE_CALLS" ;;
  *) ok "(b) already-correct label left alone, no churn" ;;
esac

# (c) no gate-status:* label present at all (fresh marker) -> just adds the
# target, zero remove calls.
MOCK_SHOW_JSON='[{"id":"ga-fresh","labels":["type:quality-gate-marker"]}]'
MOCK_LABEL_ADD_CALLS=""; MOCK_LABEL_REMOVE_CALLS=""
gate_status_transition "ga-fresh" "queued"
eq "(c) no pre-existing gate-status:* -> zero remove calls" "$MOCK_LABEL_REMOVE_CALLS" ""
case "$MOCK_LABEL_ADD_CALLS" in
  *"gate-status:queued"*) ok "(c) target label added on a fresh marker" ;;
  *) bad "(c) expected gate-status:queued to be added, got: $MOCK_LABEL_ADD_CALLS" ;;
esac

# (d) repair pass: a gate-status:* label appears BETWEEN the first read and
# the verify-by-re-read (a concurrent writer racing in, e.g.
# gate-recovery-watchdog). The stateful mock only reveals the intruder on the
# SECOND `show` call — proves the repair pass genuinely re-reads rather than
# trusting its own first snapshot.
#
# gate-fix-2 subtlety (same lesson section 3 already applies to
# _capture_out, and section 4 applies to GC_CALLS): gate_status_transition
# pipes `bd show ... | jq ...`, and bash runs each pipeline stage — including
# this mocked bd() — in a SUBSHELL. A plain shell-variable increment inside
# bd() would be invisible to the rest of THIS shell the instant that subshell
# exits, so the mock would keep re-serving call #1's response forever. Count
# via a FILE instead (real I/O survives the subshell), same technique as
# GC_CALLS in section 4 below.
MOCK_SHOW_JSON='[{"id":"ga-race","labels":["gate-status:dispatching"]}]'
MOCK_SHOW_CALL_LOG=$(mktemp)
MOCK_LABEL_ADD_CALLS=""; MOCK_LABEL_REMOVE_CALLS=""
bd() {
  case " $* " in
    *" show "*)
      echo x >> "$MOCK_SHOW_CALL_LOG"
      _n=$(wc -l < "$MOCK_SHOW_CALL_LOG" | tr -d '[:space:]')
      if [ "$_n" -ge 2 ]; then
        printf '%s\n' '[{"id":"ga-race","labels":["gate-status:error","gate-status:queued"]}]'
      else
        printf '%s\n' "$MOCK_SHOW_JSON"
      fi
      ;;
    *" label add "*)    MOCK_LABEL_ADD_CALLS="$MOCK_LABEL_ADD_CALLS|$*" ;;
    *" label remove "*) MOCK_LABEL_REMOVE_CALLS="$MOCK_LABEL_REMOVE_CALLS|$*" ;;
    *) : ;;
  esac
  return 0
}
gate_status_transition "ga-race" "error"
rm -f "$MOCK_SHOW_CALL_LOG"
case "$MOCK_LABEL_REMOVE_CALLS" in
  *"gate-status:queued"*) ok "(d) repair pass caught + removed a label that appeared AFTER the first read (race window)" ;;
  *) bad "(d) repair pass missed the raced-in label, got: $MOCK_LABEL_REMOVE_CALLS" ;;
esac

# (e) STDOUT FIDELITY — a mock that emits the REAL bd binary's confirmation
# text (verified live against an unmodified dispatcher + a real scratch bead,
# 2026-08-08: `bd label add/remove -q` prints `✓ Added/Removed label ...` to
# STDOUT, NOT suppressed by -q, and NOT on stderr — every prior mock in this
# file is silent on label add/remove, which is exactly why this class of bug
# shipped undetected). If gate_status_transition's own bd calls ever regress
# back to `2>/dev/null`-only (stderr), this test must catch the leak.
MOCK_SHOW_JSON='[{"id":"ga-fidelity","labels":["gate-status:dispatching"]}]'
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *" label add "*)    printf "%s\n" "✓ Added label 'gate-status:error' to ga-fidelity" ;;
    *" label remove "*) printf "%s\n" "✓ Removed label 'gate-status:dispatching' from ga-fidelity" ;;
    *) : ;;
  esac
  return 0
}
_capture_out gate_status_transition "ga-fidelity" "error"
eq "(e) gate_status_transition emits NOTHING to stdout even when bd's real confirmation text is present" "$CAPTURED" ""

# (f) FULL end-to-end fidelity through gate_spawn_failure_requeue_or_error —
# THE actual production bug ga-ia7m7 fixes. Pre-fix, this exact
# realistic-bd-output scenario produced a captured token like "✓ Removed
# label...\n✓ Added label...\n✓ Comment added...\nready" — NOT the literal
# "ready" — so the real caller's `[ "$(...)" = "ready" ]` check ALWAYS fell
# through to writing gate-status:error right after gate-status:ready had just
# been written, on every single transient-retry. Confirmed live before this
# fix, against the unmodified dispatcher + a real scratch bead (not just
# reasoned about) — captured token was 296 bytes, ended in "ready" but did
# not equal it; final labels included both gate-status:ready AND a leftover
# from the fall-through. Fixed by redirecting BOTH streams on every bd/comment
# call inside this function (not just stderr).
#
# Stateful mock (same convention as section 3(a) above): the counter-label
# add must be reflected in the NEXT show response, or the ga-6dp9
# verify-by-re-read check (gate_rebase_attempt_advanced) reads back "0"
# instead of "1", misreads the write as unverified, and this test would
# incorrectly exercise the "stuck" fallback path instead of the happy path
# it's meant to prove.
MOCK_SHOW_JSON='[{"id":"ga-e2e","labels":["gate-status:dispatching"]}]'
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *" label add "*)
      printf "%s\n" "✓ Added label 'x' to ga-e2e"
      case " $* " in
        *"gate:spawn-fail-count:1"*) MOCK_SHOW_JSON='[{"id":"ga-e2e","labels":["gate:spawn-fail-count:1"]}]' ;;
      esac
      ;;
    *" label remove "*) printf "%s\n" "✓ Removed label 'x' from ga-e2e" ;;
    *" comment "*)      printf "%s\n" "✓ Comment added to ga-e2e — some text" ;;
    *) : ;;
  esac
  return 0
}
RESULT=$(gate_spawn_failure_requeue_or_error "ga-e2e" "invalid connection")
eq "(f) end-to-end: captured token is EXACTLY 'ready' even with realistic noisy bd output (the actual production bug, ga-ia7m7)" "$RESULT" "ready"

# ── 4. spawn-retry-loop — genuine live extraction, in-process recovery ───────
echo "── 4. spawn-retry-loop (live extraction, mocked gc + sleep) ──"
RETRY_BLOCK="$(sed -n '/# SELFTEST-EXTRACT spawn-retry-loop: BEGIN/,/# SELFTEST-EXTRACT spawn-retry-loop: END/p' "$DISPATCHER")"
if [ -z "$RETRY_BLOCK" ]; then
  echo "FATAL: could not locate 'spawn-retry-loop' sentinel block in $DISPATCHER"
  exit 1
fi
ok "located live spawn-retry-loop block via sentinel extraction"

# is_transient_spawn_error is a genuine cross-process dependency: `bash -c`
# below spawns a SEPARATE bash interpreter, which only sees shell functions
# exported via `export -f` (plain function definitions in this shell are not
# inherited by a child bash process the way they are by a $(...) subshell of
# the SAME process). warn/sleep are deliberately NOT exported — each embedded
# script below shadows them locally as no-ops instead, so this section stays
# about retry mechanics only (section 3 already covers muteness).
#
# ga-9e8nf: the extracted spawn-retry-loop block also calls
# capture_spawn_err_tail() on every attempt now (real call site, not part of
# this test's embedded gc() mocks) — export it too, or the child bash sees
# "command not found", _spawn_err silently collapses to empty, and
# is_transient_spawn_error("") reads NOT transient — the loop then exits
# after exactly 1 attempt instead of retrying, independent of what the
# mocked gc() actually does. Confirmed live while wiring ga-9e8nf: sections
# 4/4b below failed with GC_CALLS=1 (loop never reached its 2nd/3rd attempt)
# until this export was added.
export -f is_transient_spawn_error
export -f capture_spawn_err_tail

# (a) first attempt failed transiently; the mocked `gc session new` succeeds
# on its SECOND call (the in-process retry) — the loop must recover without
# ever touching the marker's gate-status (this function never calls bd at
# all, by design).
#
# ga-2u38b regression note (found while writing this test): the real code
# calls gc via `SESSION_JSON=$(gc ... || echo "{}")` — a command
# substitution, which forks a SUBSHELL. A mock that counts calls with a
# plain `GC_CALLS=$((GC_CALLS + 1))` shell-variable increment loses every
# increment the instant that subshell exits — the SAME subshell-visibility
# lesson section 3 already applied to _capture_out, hitting again one layer
# lower (mocking an external command instead of a function). Count via a
# FILE (append + wc -l) instead — real I/O, so it survives the subshell.
GC_RETRY_SCRIPT='
CALL_LOG=$(mktemp)
gc() {
  echo x >> "$CALL_LOG"
  n=$(wc -l < "$CALL_LOG" | tr -d "[:space:]")
  if [ "$n" -ge 2 ]; then
    printf "{\"session_id\":\"sess-recovered\"}"
  else
    echo "invalid connection" >&2
    return 1
  fi
}
sleep() { :; }
warn() { :; }
i=1; BRANCH="fix/ga-2u38b"; GC_CITY="test-city"
SESSION_ID=""; _spawn_err="invalid connection"
GATE_SPAWN_RETRY_MAX=2; GATE_SPAWN_RETRY_BACKOFF_SECS=0
'"$RETRY_BLOCK"'
GC_CALLS=$(wc -l < "$CALL_LOG" | tr -d "[:space:]")
rm -f "$CALL_LOG"
printf "SESSION_ID=%s GC_CALLS=%s\n" "$SESSION_ID" "$GC_CALLS"
'
OUT=$(bash -c "$GC_RETRY_SCRIPT" 2>/dev/null)
case "$OUT" in
  "SESSION_ID=sess-recovered GC_CALLS=2") ok "(a) in-process retry recovered on the 2nd attempt without exhausting the run (matches ACEITE's 'retry curto antes de desistir')" ;;
  *) bad "(a) expected SESSION_ID=sess-recovered GC_CALLS=2, got: $OUT" ;;
esac

# (b) failure persists across every in-process attempt → loop respects
# GATE_SPAWN_RETRY_MAX and stops (does not spin forever); SESSION_ID stays
# empty so the caller's classify-and-requeue path still runs.
GC_ALWAYS_FAIL_SCRIPT='
CALL_LOG=$(mktemp)
gc() { echo x >> "$CALL_LOG"; echo "invalid connection" >&2; return 1; }
sleep() { :; }
warn() { :; }
i=1; BRANCH="fix/ga-2u38b"; GC_CITY="test-city"
SESSION_ID=""; _spawn_err="invalid connection"
GATE_SPAWN_RETRY_MAX=2; GATE_SPAWN_RETRY_BACKOFF_SECS=0
'"$RETRY_BLOCK"'
GC_CALLS=$(wc -l < "$CALL_LOG" | tr -d "[:space:]")
rm -f "$CALL_LOG"
printf "SESSION_ID=%s GC_CALLS=%s\n" "$SESSION_ID" "$GC_CALLS"
'
OUT=$(bash -c "$GC_ALWAYS_FAIL_SCRIPT" 2>/dev/null)
# GATE_SPAWN_RETRY_MAX=2 bounds the retries INSIDE the extracted block to
# exactly 2 calls to gc() (the initial attempt happens above the extracted
# block in the real dispatcher and is not part of what's being measured here).
case "$OUT" in
  "SESSION_ID= GC_CALLS=2") ok "(b) persistent failure stops at GATE_SPAWN_RETRY_MAX (no infinite retry), SESSION_ID left empty for the caller to classify" ;;
  *) bad "(b) expected SESSION_ID= GC_CALLS=2 (bounded, not unbounded), got: $OUT" ;;
esac

# (c) non-transient error → the loop must NOT retry at all (zero extra gc calls).
GC_NONTRANSIENT_SCRIPT='
CALL_LOG=$(mktemp)
gc() { echo x >> "$CALL_LOG"; echo "template not found" >&2; return 1; }
sleep() { :; }
warn() { :; }
i=1; BRANCH="fix/ga-2u38b"; GC_CITY="test-city"
SESSION_ID=""; _spawn_err="template not found"
GATE_SPAWN_RETRY_MAX=2; GATE_SPAWN_RETRY_BACKOFF_SECS=0
'"$RETRY_BLOCK"'
GC_CALLS=$(wc -l < "$CALL_LOG" 2>/dev/null | tr -d "[:space:]"); GC_CALLS="${GC_CALLS:-0}"
rm -f "$CALL_LOG"
printf "SESSION_ID=%s GC_CALLS=%s\n" "$SESSION_ID" "$GC_CALLS"
'
OUT=$(bash -c "$GC_NONTRANSIENT_SCRIPT" 2>/dev/null)
case "$OUT" in
  "SESSION_ID= GC_CALLS=0") ok "(c) non-transient spawn_err gets ZERO in-process retries — falls straight to classification, same as before this fix" ;;
  *) bad "(c) expected SESSION_ID= GC_CALLS=0 (no retry on a non-transient error), got: $OUT" ;;
esac

# ── 4b. ga-3jn3a: real shipped defaults survive the exact live-incident shape ─
echo "── 4b. spawn-retry-loop with REAL shipped defaults (ga-3jn3a) ──"

# Pull the real GATE_SPAWN_RETRY_MAX/BACKOFF_SECS default-assignment lines
# verbatim too (distinct from RETRY_BLOCK, the loop body) — tests (d)/(e)
# below must exercise what actually SHIPS, not a value re-typed by hand here
# that could silently drift from the source.
DEFAULTS_BLOCK="$(grep -E '^GATE_SPAWN_RETRY_(MAX|BACKOFF_SECS)=' "$DISPATCHER")"
if [ -z "$DEFAULTS_BLOCK" ]; then
  echo "FATAL: could not locate GATE_SPAWN_RETRY_MAX/BACKOFF_SECS default assignments in $DISPATCHER"
  exit 1
fi

# (d) THE ACEITE test, verbatim: inject a transient-connection failure on TWO
# consecutive attempts, using the dispatcher's own real defaults (DEFAULTS_BLOCK,
# NOT hand-set here unlike (a)-(c) above) — the run must recover on the 3rd
# attempt rather than exhausting the retry budget after 2 failures the way the
# pre-fix GATE_SPAWN_RETRY_MAX=1 shape did on 2026-08-06 (39s outage, 2
# failures 39s apart, straight to gate-status:error — the incident this fix
# exists for).
GC_TWO_FAILURES_SCRIPT='
CALL_LOG=$(mktemp)
gc() {
  echo x >> "$CALL_LOG"
  n=$(wc -l < "$CALL_LOG" | tr -d "[:space:]")
  if [ "$n" -ge 3 ]; then
    printf "{\"session_id\":\"sess-recovered\"}"
  else
    echo "invalid connection" >&2
    return 1
  fi
}
sleep() { :; }
warn() { :; }
i=1; BRANCH="fix/ga-3jn3a"; GC_CITY="test-city"
SESSION_ID=""; _spawn_err="invalid connection"
'"$DEFAULTS_BLOCK"'
'"$RETRY_BLOCK"'
GC_CALLS=$(wc -l < "$CALL_LOG" | tr -d "[:space:]")
rm -f "$CALL_LOG"
printf "SESSION_ID=%s GC_CALLS=%s MAX=%s\n" "$SESSION_ID" "$GC_CALLS" "$GATE_SPAWN_RETRY_MAX"
'
OUT=$(bash -c "$GC_TWO_FAILURES_SCRIPT" 2>/dev/null)
case "$OUT" in
  "SESSION_ID=sess-recovered GC_CALLS=3 MAX=3")
    ok "(d) ACEITE: 2 consecutive transient failures + shipped defaults (MAX=3) recover on the 3rd attempt, never reach gate-status:error" ;;
  *" MAX=1")
    bad "(d) GATE_SPAWN_RETRY_MAX default is still 1 — the pre-fix value — 2 consecutive failures would still exhaust the budget: $OUT" ;;
  *)
    bad "(d) expected SESSION_ID=sess-recovered GC_CALLS=3 MAX=3, got: $OUT" ;;
esac

# (e) backoff GROWS per attempt (doubles from the base) instead of repeating
# the same short wait every time — capture the actual computed sleep
# durations via a sleep() mock that logs its argument to a file (same
# survives-the-subshell technique as the gc() CALL_LOG mocks above, since
# sleep() here also runs inside the command-substitution subshell — a plain
# shell-variable accumulator would lose every append the instant that
# subshell exits, same lesson as CALL_LOG above).
GC_BACKOFF_CAPTURE_SCRIPT='
SLEEP_LOG=$(mktemp)
gc() { echo "invalid connection" >&2; return 1; }
sleep() { printf "%s\n" "$1" >> "$SLEEP_LOG"; }
warn() { :; }
i=1; BRANCH="fix/ga-3jn3a"; GC_CITY="test-city"
SESSION_ID=""; _spawn_err="invalid connection"
'"$DEFAULTS_BLOCK"'
'"$RETRY_BLOCK"'
cat "$SLEEP_LOG"
rm -f "$SLEEP_LOG"
'
BACKOFFS=$(bash -c "$GC_BACKOFF_CAPTURE_SCRIPT" 2>/dev/null | tr "\n" "," | sed "s/,$//")
if [ "$BACKOFFS" = "3,6,12" ]; then
  ok "(e) backoff doubles per attempt from the base (3,6,12 — not a flat 3,3,3): $BACKOFFS"
else
  bad "(e) expected doubling backoff '3,6,12', got: '$BACKOFFS'"
fi

# ── 4c. ga-9e446u: the retry waits for Dolt to ANSWER, not only for a fixed backoff ──
# Measured on the live log: of 15 reviewer spawns that needed a retry, 8 still aborted after all
# 3 retries (3s/6s/12s = 21s of backoff) because the Dolt-connection windows behind them last
# ~4 minutes — each abort burned a fully-paid-for run and bumped gate-spawn-abort-count (3 in a
# row pages the Mayor as a systemic outage). gate_spawn_wait_dolt_ready asks Dolt (ga-gs3bj3: a
# direct bounded `dolt sql -q 'SELECT 1'`, no longer `gc dolt health`) between the backoff and
# the retry, bounded, and the retry happens anyway when the budget is spent. Every scenario below
# runs the REAL extracted loop + the REAL extracted wait functions in a child bash with mocked
# gc / dolt / date / timeout / sleep / warn; counts go through files (the real code calls them
# inside $(...), a subshell — the same lesson as CALL_LOG above).
echo "── 4c. spawn retry waits for Dolt readiness (ga-9e446u) ──"
WAIT_BLOCK="$(sed -n '/# SELFTEST-EXTRACT gate-spawn-dolt-wait: BEGIN/,/# SELFTEST-EXTRACT gate-spawn-dolt-wait: END/p' "$DISPATCHER")"
if [ -z "$WAIT_BLOCK" ]; then
  echo "FATAL: could not locate 'gate-spawn-dolt-wait' sentinel block in $DISPATCHER (ga-9e446u not applied?)"
  exit 1
fi
ok "located live gate-spawn-dolt-wait block via sentinel extraction"
export -f gc_json_or_unknown

WAIT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-spawn-dolt-wait-selftest.XXXXXX")"
trap 'rm -rf "$WAIT_TMP"' EXIT
# The pack's runtime state file (.gc/runtime/packs/dolt/dolt-state.json), as the verdict reads it.
printf '{"running":true,"pid":1,"port":52756,"data_dir":"/x","started_at":"2026-10-08T02:44:43Z"}' > "$WAIT_TMP/state.ok.json"
printf '{"running":false,"pid":0,"port":52756}' > "$WAIT_TMP/state.stopped.json"
printf '{"pid":1,"port":52756}' > "$WAIT_TMP/state.norunning.json"
printf '{"running":true,"pid":1}' > "$WAIT_TMP/state.noport.json"
printf '{"running":true,"pid":1,"port":"52756; touch /tmp/pwned"}' > "$WAIT_TMP/state.hostileport.json"
printf 'not json at all' > "$WAIT_TMP/state.junk.json"
# The child's mocks. PROBE_SEQ is a space-separated list of what the Nth direct `dolt ... sql -q
# 'SELECT 1'` probe does (the last word repeats): ok = answers, takes 120ms | hot = answers, takes
# 9000ms | edge = answers, takes $EDGE_MS | down = connection refused, exit 1 (the server is gone; the
# state file still says running:true — the realistic crash shape) | hung = TCP up but SQL wedged: the
# probe runs into `timeout 5` and exits 124 | nofield = exit 0 but prints no `1` row | junk = exit 0
# with a non-table | refused = the probe command itself cannot run (exit 127). Time is VIRTUAL: the
# `dolt` mock advances a ms clock file and `date +%s%N` reads it, so latency is exact and nothing
# really waits. `gc dolt health` is mocked as the loaded-Dolt reality (it hangs to the 15s timeout,
# exit 124) and every call is COUNTED in $W/healths — the new verdict must never make one. A
# `gc dolt sql` mock answers a perfect `| 1 |` table with exit 0 even for a dead Dolt (the real
# embedded fallback, packs/dolt/commands/sql/run.sh) and counts in $W/gcsql — the verdict must never
# ask it either. SPAWN_OK_AT = the Nth `gc session new` that succeeds (unset =
# never). SLEEP_ADVANCE = make each mocked sleep advance $SECONDS by N x its argument, to model
# real time passing (a stalled probe) without really sleeping. STATE_FILE = which pack state
# file the verdict reads (default: running:true, port 52756). NOCLOCK=1 = no ms clock anywhere.
cat > "$WAIT_TMP/prelude.sh" <<'PRELUDE'
W="${SC_WORK:?}"
PROBES="$W/probes"; SPAWNS="$W/spawns"; SLEEPS="$W/sleeps"; WARNS="$W/warns"; HEALTHS="$W/healths"; GCSQL="$W/gcsql"
: > "$PROBES"; : > "$SPAWNS"; : > "$SLEEPS"; : > "$WARNS"; : > "$HEALTHS"; : > "$GCSQL"
echo 1700000000000 > "$W/clock"
GATE_DOLT_STATE_FILE="${STATE_FILE:-$W/state.ok.json}"
_tick() { echo $(( $(cat "$W/clock") + $1 )) > "$W/clock"; }
date() {
  case "$*" in
    *%s%N*) if [ -n "${NOCLOCK:-}" ]; then printf '%sN' "$(cat "$W/clock" | cut -c1-10)"; else printf '%s000000' "$(cat "$W/clock")"; fi ;;
    *) command date "$@" ;;
  esac
}
gdate() { return 1; }
perl() { [ -z "${NOCLOCK:-}" ] || return 1; printf '%s' "$(cat "$W/clock")"; }
_nth() { local _s="$1" _n="$2" _w; set -- $_s; if [ "$_n" -le "$#" ]; then eval "_w=\${$_n}"; else eval "_w=\${$#}"; fi; printf '%s' "$_w"; }
# DOWN_FOR=N (with SLEEP_ADVANCE=1) models a Dolt outage on a VIRTUAL clock: Dolt is down until N
# mocked-sleep seconds have passed, and BOTH the readiness probe and `session new` follow it — so a
# retry that lands too early really fails, and only waiting out the outage recovers. The virtual
# time is the SUM OF THE MOCKED SLEEPS (x SLEEP_ADVANCE), never $SECONDS: $SECONDS also counts the
# REAL time the probe's forks take (~1s a round at load 60), which moved the recovery a poll early.
_dolt_up() {
  [ -n "${DOWN_FOR:-}" ] || return 1
  [ $(( $(awk '{ s += $1 } END { printf "%d", s }' "$SLEEPS") * ${SLEEP_ADVANCE:-1} )) -ge "$DOWN_FOR" ]
}
# The probe the verdict runs: `timeout 5 dolt --host 127.0.0.1 --port N --user root --no-tls sql -q 'SELECT 1'`
# (`timeout` is mocked below to just run its command). One `dolt` call = one readiness probe.
dolt() {
  echo p >> "$PROBES"
  _pn=$(wc -l < "$PROBES" | tr -d '[:space:]')
  if [ -n "${DOWN_FOR:-}" ]; then
    if _dolt_up; then _pw=ok; else _pw=down; fi
  else
    _pw="$(_nth "$PROBE_SEQ" "$_pn")"
  fi
  case "$_pw" in
    ok)      _tick 120; printf '+---+\n| 1 |\n+---+\n| 1 |\n+---+\n' ;;
    hot)     _tick 9000; printf '+---+\n| 1 |\n+---+\n| 1 |\n+---+\n' ;;
    edge)    _tick "${EDGE_MS:-2500}"; printf '+---+\n| 1 |\n+---+\n| 1 |\n+---+\n' ;;
    down)    _tick 50; echo "dial tcp 127.0.0.1:52756: connect: connection refused" >&2; return 1 ;;
    hung)    _tick 5000; return 124 ;;
    nofield) printf 'Query OK, 0 rows affected\n' ;;
    junk)    printf 'not a table at all' ;;
    *)       return 127 ;;   # refused = the probe command itself cannot run
  esac
}
gc() {
  case "$*" in
    *"dolt health"*)
      # what `gc dolt health --json` REALLY does on a loaded-but-healthy Dolt (ga-gs3bj3, load 60): it scans
      # every database after its SELECT 1 and runs past the old 15s timeout. The verdict must not wait for it.
      echo h >> "$HEALTHS"; _tick 15000; return 124 ;;
    *"dolt sql"*)
      # the EMBEDDED fallback: with no server reachable `gc dolt sql` opens the data dir itself and prints this
      # same table with exit 0 — so it can never be the source of a "ready".
      echo q >> "$GCSQL"; printf '+---+\n| 1 |\n+---+\n| 1 |\n+---+\n'; return 0 ;;
    *"session new"*)
      echo s >> "$SPAWNS"
      _sn=$(wc -l < "$SPAWNS" | tr -d '[:space:]')
      if [ -n "${DOWN_FOR:-}" ]; then
        if _dolt_up; then printf '{"session_id":"sess-recovered"}'; else echo "invalid connection" >&2; return 1; fi
      elif [ -n "${SPAWN_OK_AT:-}" ] && [ "$_sn" -ge "$SPAWN_OK_AT" ]; then
        printf '{"session_id":"sess-recovered"}'
      else
        echo "invalid connection" >&2; return 1
      fi ;;
  esac
}
timeout() { shift; "$@"; }   # the real `timeout` exec()s a binary and cannot see the gc function above
sleep() {
  printf '%s\n' "$1" >> "$SLEEPS"
  [ -z "${SLEEP_ADVANCE:-}" ] || SECONDS=$((SECONDS + $1 * SLEEP_ADVANCE))
  # runaway guard: an unbounded wait loop must FAIL this test (no summary line), not hang it.
  # sleep is called directly by the loops under test, so this exit ends the child itself.
  [ "$(wc -l < "$SLEEPS" | tr -d '[:space:]')" -le 400 ] || exit 99
}
warn() { printf '%s\n' "$*" >> "$WARNS"; }
i=1; BRANCH="fix/ga-9e446u"; GC_CITY="test-city"; SESSION_ID=""; _spawn_err="${SPAWN_ERR:-invalid connection}"
GATE_SPAWN_RETRY_MAX=3; GATE_SPAWN_RETRY_BACKOFF_SECS=3
GATE_SPAWN_DOLT_WAIT_SECS="${KNOB_WAIT:-60}"; GATE_SPAWN_DOLT_POLL_SECS="${KNOB_POLL:-10}"
GATE_DOLT_LATENCY_HOT_MS=2500
PRELUDE
cat > "$WAIT_TMP/tail.sh" <<'TAIL'
printf 'SESSION_ID=%s SPAWNS=%s PROBES=%s SLEEPS=%s\n' "$SESSION_ID" \
  "$(wc -l < "$SPAWNS" | tr -d '[:space:]')" "$(wc -l < "$PROBES" | tr -d '[:space:]')" \
  "$(tr '\n' ',' < "$SLEEPS" | sed 's/,$//')"
TAIL
# run_wait <probe_seq> [VAR=value ...] → the child's one-line summary
run_wait() {
  local _seq="$1"; shift
  { cat "$WAIT_TMP/prelude.sh"; printf '%s\n' "$WAIT_BLOCK"; printf '%s\n' "$RETRY_BLOCK"; cat "$WAIT_TMP/tail.sh"; } > "$WAIT_TMP/child.sh"
  env SC_WORK="$WAIT_TMP" PROBE_SEQ="$_seq" "$@" bash "$WAIT_TMP/child.sh" 2>/dev/null || true   # a killed (runaway) child = empty summary = a failed check, not a dead selftest
}
# run_verdict <probe_word> [VAR=value ...] → what the REAL gate_dolt_ready_verdict prints for ONE direct
# SELECT 1 probe of that shape. The pointed check: when this fails the defect is in the verdict, not in the loop.
run_verdict() {
  { cat "$WAIT_TMP/prelude.sh"; printf '%s\n' "$WAIT_BLOCK"; printf '%s\n' 'gate_dolt_ready_verdict'; } > "$WAIT_TMP/verdict.sh"
  env SC_WORK="$WAIT_TMP" PROBE_SEQ="$1" "${@:2}" bash "$WAIT_TMP/verdict.sh" 2>/dev/null || true
}

# (v) THE VERDICT, shape by shape. The variable the verdict DECIDES on must say Dolt ANSWERED `SELECT 1`
# (exit 0 AND the `1` row), not a number that is 0 when it did not. ga-9e446u gate round 1: a down Dolt
# printed "ready" here, so the whole wait was a no-op in the outage it exists for.
eq "(v1) the probe answers in 120ms → ready" "$(run_verdict ok)" "ready"
eq "(v2) the probe answers in 9000ms → hot" "$(run_verdict hot)" "hot"
eq "(v3) the server is gone (probe refused, exit 1; state file still running:true) → down, NOT ready" "$(run_verdict down)" "down"
eq "(v4) TCP up but SQL wedged (the probe runs into timeout 5, exit 124) → down, NOT ready" "$(run_verdict hung)" "down"
eq "(v5) exit 0 but no \`1\` row can't say Dolt answered → unreadable, NOT ready" "$(run_verdict nofield)" "unreadable"
eq "(v6) exit 0 with a non-table → unreadable" "$(run_verdict junk)" "unreadable"
eq "(v7) the probe command itself cannot run (exit 127) → unreadable" "$(run_verdict refused)" "unreadable"
eq "(v8) answers, exactly the ceiling → ready" "$(run_verdict edge EDGE_MS=2500)" "ready"
eq "(v9) answers, one over the ceiling → hot" "$(run_verdict edge EDGE_MS=2501)" "hot"

# (v10-v14) the pack's state file is the only place the port comes from. tem / não-tem / não-consegui-saber:
# running:false is a clear NO (down, and no probe is made); a missing/garbled/portless file is "can't say".
eq "(v10) state says running:false → down, without probing" "$(run_verdict ok STATE_FILE="$WAIT_TMP/state.stopped.json")" "down"
eq "(v10b) ... and the probe was NOT made (it would have said ready)" "$(wc -l < "$WAIT_TMP/probes" | tr -d '[:space:]')" "0"
eq "(v11) no state file at all → unreadable, NOT ready" "$(run_verdict ok STATE_FILE="$WAIT_TMP/nope.json")" "unreadable"
eq "(v12) garbled state file → unreadable" "$(run_verdict ok STATE_FILE="$WAIT_TMP/state.junk.json")" "unreadable"
eq "(v12b) state without a boolean .running → unreadable" "$(run_verdict ok STATE_FILE="$WAIT_TMP/state.norunning.json")" "unreadable"
eq "(v13) state without a port → unreadable (the probe is not guessed at some default port)" "$(run_verdict ok STATE_FILE="$WAIT_TMP/state.noport.json")" "unreadable"
eq "(v14) a non-numeric port never reaches the dolt command line → unreadable" "$(run_verdict ok STATE_FILE="$WAIT_TMP/state.hostileport.json")" "unreadable"
eq "(v14b) ... and no probe ran for it" "$(wc -l < "$WAIT_TMP/probes" | tr -d '[:space:]')" "0"

# (v15) ga-gs3bj3 ACCEPTANCE (a): a HEALTHY but LOADED Dolt. `gc dolt health --json` runs past its 15s timeout
# (measured 13-40s at load 60) while the SELECT 1 answers at once. On the pre-ga-gs3bj3 verdict this is
# "unreadable" (it waited on health), so this check FAILS there — the pointed regression test for the bead.
eq "(v15) Dolt healthy+loaded: \`gc dolt health\` would hang, the SELECT 1 answers in 120ms → ready" "$(run_verdict ok)" "ready"
eq "(v15b) ... and the verdict never asked \`gc dolt health\`" "$(wc -l < "$WAIT_TMP/healths" | tr -d '[:space:]')" "0"

# (v16) THE TRAP the obvious swap falls into: `gc dolt sql -q 'SELECT 1'` with no server reachable opens the
# data dir EMBEDDED and prints the same table with exit 0. With the mock answering exactly that, a verdict
# built on it would say "ready" for a dead Dolt. Ours probes the server directly: refused → down.
eq "(v16) dead Dolt while \`gc dolt sql\` would answer from the embedded fallback → down, NOT ready" "$(run_verdict down)" "down"
eq "(v16b) ... and \`gc dolt sql\` was never asked" "$(wc -l < "$WAIT_TMP/gcsql" | tr -d '[:space:]')" "0"

# (v17-v18) the latency is only a measurement if the clock is: no ms clock → can't say; a clock that stepped
# back mid-probe (negative latency) → can't say. Neither may read as "ready" (nor as a fast 0ms).
eq "(v17) no ms clock anywhere (date prints a literal N, no gdate, no perl) → unreadable, NOT ready" "$(run_verdict ok NOCLOCK=1)" "unreadable"
eq "(v18) the clock stepped back during the probe (-5ms) → unreadable, NOT a 0ms ready" "$(run_verdict edge EDGE_MS=-5)" "unreadable"

# (g) THE FIX: Dolt is down for the first two probes, then answers. The retry must WAIT (two 10s
# polls after the 3s backoff) and then spawn once, successfully — on HEAD~ the loop retried straight
# after the 3s backoff, into a Dolt that was still down, and burned a retry.
OUT=$(run_wait "down down ok" SPAWN_OK_AT=1)
eq "(g) Dolt down,down,ok: retry waits 2 polls after the backoff, then spawns once and recovers" \
  "$OUT" "SESSION_ID=sess-recovered SPAWNS=1 PROBES=3 SLEEPS=3,10,10"

# (g2) the end-to-end shape of the abort this bead is about: Dolt is back only after the whole
# 21s of backoff would have been spent — with the wait the SECOND retry finds it and spawns.
OUT=$(run_wait "down down down down down down down down ok" SPAWN_OK_AT=2)
case "$OUT" in
  "SESSION_ID=sess-recovered SPAWNS=2 "*) ok "(g2) a Dolt outage longer than the whole backoff ladder is bridged by the wait (recovered on retry 2): $OUT" ;;
  *) bad "(g2) expected recovery on spawn 2 across a long Dolt outage, got: $OUT" ;;
esac

# (g3) CAUSAL, on a virtual clock: Dolt is down for 40 virtual seconds and `session new` fails until
# then. The pre-ga-9e446u ladder (WAIT=0 — the exact old loop) retries at t+3, t+9, t+21 — all inside
# the outage — and burns all 3. The wait polls Dolt out of the outage and the FIRST retry lands.
OUT=$(run_wait "" DOWN_FOR=40 SLEEP_ADVANCE=1 KNOB_WAIT=0)
eq "(g3) 40s Dolt outage, wait OFF (the old ladder, 21s): all 3 retries land inside the outage and fail" \
  "$OUT" "SESSION_ID= SPAWNS=3 PROBES=0 SLEEPS=3,6,12"
OUT=$(run_wait "" DOWN_FOR=40 SLEEP_ADVANCE=1)
eq "(g3b) the same 40s outage, wait ON: polls until Dolt answers, then the first retry recovers" \
  "$OUT" "SESSION_ID=sess-recovered SPAWNS=1 PROBES=5 SLEEPS=3,10,10,10,10"
# (g3c) an outage longer than ONE wait budget (60s): the first retry gives up the wait and fails, the
# second retry's wait finds Dolt back — recovery on spawn 2, where the old ladder never recovers.
OUT=$(run_wait "" DOWN_FOR=100 SLEEP_ADVANCE=1)
case "$OUT" in
  "SESSION_ID=sess-recovered SPAWNS=2 "*) ok "(g3c) a 100s outage outlasts one wait budget but not two: recovered on retry 2: $OUT" ;;
  *) bad "(g3c) expected recovery on spawn 2 after a 100s outage, got: $OUT" ;;
esac
OUT=$(run_wait "" DOWN_FOR=100 SLEEP_ADVANCE=1 KNOB_WAIT=0)
eq "(g3d) the same 100s outage, wait OFF: the old ladder never recovers" "$OUT" "SESSION_ID= SPAWNS=3 PROBES=0 SLEEPS=3,6,12"

# (h) Dolt answering but SLOW (latency over the hot ceiling) is not ready either; unreadable is not
# ready (a probe that cannot answer right after a connection error IS the outage).
OUT=$(run_wait "hot hot ok" SPAWN_OK_AT=1)
eq "(h) latency 9000ms is not ready: waits until it drops to 120ms" "$OUT" "SESSION_ID=sess-recovered SPAWNS=1 PROBES=3 SLEEPS=3,10,10"
OUT=$(run_wait "junk junk ok" SPAWN_OK_AT=1)
eq "(h2) a probe that answers junk is not ready" "$OUT" "SESSION_ID=sess-recovered SPAWNS=1 PROBES=3 SLEEPS=3,10,10"
OUT=$(run_wait "edge" SPAWN_OK_AT=1 EDGE_MS=2500)
eq "(h3) latency exactly at the ceiling (2500ms) is ready — no wait" "$OUT" "SESSION_ID=sess-recovered SPAWNS=1 PROBES=1 SLEEPS=3"
OUT=$(run_wait "edge edge" SPAWN_OK_AT=1 EDGE_MS=2501 KNOB_WAIT=10 KNOB_POLL=10)
case "$OUT" in
  "SESSION_ID=sess-recovered SPAWNS=1 PROBES=2 "*) ok "(h4) latency 2501ms is hot: waited the one poll the 10s budget allows, then retried anyway: $OUT" ;;
  *) bad "(h4) expected 2 probes (hot, then give up and retry), got: $OUT" ;;
esac
OUT=$(run_wait "hung hung ok" SPAWN_OK_AT=1)
eq "(h5) TCP up but SQL wedged (the probe times out, exit 124) is not ready: waits until it answers" "$OUT" "SESSION_ID=sess-recovered SPAWNS=1 PROBES=3 SLEEPS=3,10,10"
OUT=$(run_wait "refused refused ok" SPAWN_OK_AT=1)
eq "(h6) a probe command that cannot run (exit 127) is not ready either (the command-fails shape)" "$OUT" "SESSION_ID=sess-recovered SPAWNS=1 PROBES=3 SLEEPS=3,10,10"
OUT=$(run_wait "nofield nofield ok" SPAWN_OK_AT=1)
eq "(h7) an exit-0 probe that printed no \`1\` row is not ready: waits" "$OUT" "SESSION_ID=sess-recovered SPAWNS=1 PROBES=3 SLEEPS=3,10,10"
# (h8) the wait's LOG must say Dolt was DOWN. Round 1 left no line at all when the wait was skipped, so the
# log read "Dolt was fine, the spawn failed anyway" — the opposite of what happened.
run_wait "down down ok" SPAWN_OK_AT=1 >/dev/null
case "$(cat "$WAIT_TMP/warns" 2>/dev/null)" in
  *"Dolt down — waiting"*) ok "(h8) a down Dolt is LOGGED as down while the retry waits" ;;
  *) bad "(h8) the wait logged no 'Dolt down — waiting' line: $(tr '\n' '|' < "$WAIT_TMP/warns" 2>/dev/null)" ;;
esac

# (i) NON-REGRESSION: Dolt healthy from the start → no extra sleep at all, the ladder is exactly
# the pre-ga-9e446u 3,6,12 and one probe per retry.
OUT=$(run_wait "ok")
eq "(i) Dolt ready immediately: sleeps are ONLY the backoff ladder 3,6,12; one probe per retry; 3 spawns" \
  "$OUT" "SESSION_ID= SPAWNS=3 PROBES=3 SLEEPS=3,6,12"

# (j) BOUNDED: Dolt never comes back. The wait spends its budget (60s/10s = 6 polls → 7 probes) per
# retry and the retry happens ANYWAY — still exactly GATE_SPAWN_RETRY_MAX spawns, never more.
OUT=$(run_wait "down")
eq "(j) Dolt never ready: 3 spawns (the wait adds no attempt), 7 probes per retry (bounded, not a spin)" \
  "$OUT" "SESSION_ID= SPAWNS=3 PROBES=21 SLEEPS=3,10,10,10,10,10,10,6,10,10,10,10,10,10,12,10,10,10,10,10,10"
case "$(cat "$WAIT_TMP/warns" 2>/dev/null)" in
  *"retrying anyway (ga-9e446u)"*) ok "(j2) giving up the wait is LOGGED ('retrying anyway'), not silent" ;;
  *) bad "(j2) the exhausted wait left no 'retrying anyway' log line" ;;
esac

# (k) BOUNDED BY THE CLOCK too: a probe that stalls (time passes while it hangs) must eat the budget.
# SLEEP_ADVANCE=10 makes the 10s poll look like 100s passing → the second probe already finds the 60s
# budget spent, so each retry costs 2 probes, not 7.
OUT=$(run_wait "down" SLEEP_ADVANCE=10)
case "$OUT" in
  "SESSION_ID= SPAWNS=3 PROBES=6 "*) ok "(k) wall-clock budget cuts the wait short when time really passes (2 probes per retry): $OUT" ;;
  *) bad "(k) expected SPAWNS=3 PROBES=6 under a clock that outruns the poll count, got: $OUT" ;;
esac

# (l) KILL SWITCH: GATE_SPAWN_DOLT_WAIT_SECS=0 → Dolt is never asked; the exact old loop.
OUT=$(run_wait "ok" KNOB_WAIT=0)
eq "(l) GATE_SPAWN_DOLT_WAIT_SECS=0: zero probes, backoff ladder only (exact pre-ga-9e446u behaviour)" \
  "$OUT" "SESSION_ID= SPAWNS=3 PROBES=0 SLEEPS=3,6,12"

# (m) NON-TRANSIENT failure: the loop is not entered at all — no probe, no sleep, no retry.
OUT=$(run_wait "ok" SPAWN_ERR="template 'gate-reviewer' not found")
eq "(m) a non-transient spawn error never reaches the wait (no probe, no sleep, no retry)" \
  "$OUT" "SESSION_ID= SPAWNS=0 PROBES=0 SLEEPS="

# (n) the shipped defaults, read from the dispatcher under lib-only sourcing (not re-typed here).
eq "shipped GATE_SPAWN_DOLT_WAIT_SECS default" "$GATE_SPAWN_DOLT_WAIT_SECS" "60"
eq "shipped GATE_SPAWN_DOLT_POLL_SECS default" "$GATE_SPAWN_DOLT_POLL_SECS" "10"

# (o) hostile knob values, through the REAL sanitiser (a fresh lib-only child per value): a junk
# budget falls back to 60, a junk poll to 10, and a poll of 0 is clamped to 1 — unclamped it divides
# by zero in the poll-count bound the first time the wait runs.
KNOBS=$(GATE_SPAWN_DOLT_WAIT_SECS=abc GATE_SPAWN_DOLT_POLL_SECS=xyz GATE_DISPATCHER_LIB_ONLY=1 \
  bash -c 'source "$1" >/dev/null 2>&1; printf "%s/%s" "$GATE_SPAWN_DOLT_WAIT_SECS" "$GATE_SPAWN_DOLT_POLL_SECS"' _ "$DISPATCHER" 2>/dev/null) || KNOBS="source-failed"
eq "(o) non-numeric WAIT/POLL fall back to the shipped 60/10" "$KNOBS" "60/10"
KNOBS=$(GATE_SPAWN_DOLT_WAIT_SECS=30 GATE_SPAWN_DOLT_POLL_SECS=0 GATE_DISPATCHER_LIB_ONLY=1 \
  bash -c 'source "$1" >/dev/null 2>&1; printf "%s/%s" "$GATE_SPAWN_DOLT_WAIT_SECS" "$GATE_SPAWN_DOLT_POLL_SECS"' _ "$DISPATCHER" 2>/dev/null) || KNOBS="source-failed"
eq "(o2) POLL=0 is clamped to 1 (no divide-by-zero), a valid WAIT is kept" "$KNOBS" "30/1"

# ── 5. drift-guards: shipped dispatcher still carries the ga-2u38b fix ───────
echo "── 5. drift-guards ──"
has "$DISPATCHER" 'is_transient_spawn_error\(\)' "transient classifier present"
has "$DISPATCHER" 'gate_spawn_failure_requeue_or_error\(\)' "decision/apply function present"
has "$DISPATCHER" 'GATE_SPAWN_TRANSIENT_MAX_ATTEMPTS' "attempt cap is a configurable GATE_\* tunable (house convention)"
has "$DISPATCHER" 'GATE_SPAWN_RETRY_MAX' "in-process retry count is a configurable GATE_\* tunable"
has "$DISPATCHER" 'GATE_SPAWN_RETRY_MAX:-3' "ga-3jn3a: default retry count raised to 3 (was 1 — too low for the observed ~39s outage)"
grep -qF '_spawn_backoff_secs=$((GATE_SPAWN_RETRY_BACKOFF_SECS * (1 << (_spawn_retry_n - 1))))' "$DISPATCHER" \
  && ok "ga-3jn3a: backoff doubles per attempt (not a flat repeat)" \
  || bad "ga-3jn3a: doubling backoff formula not found — did the retry loop get refactored?"
has "$DISPATCHER" '# SELFTEST-EXTRACT spawn-retry-loop: BEGIN' "spawn-retry-loop extraction sentinel present"
has "$DISPATCHER" '# SELFTEST-EXTRACT gate-spawn-dolt-wait: BEGIN' "gate-spawn-dolt-wait extraction sentinel present (ga-9e446u)"
# ga-gs3bj3 drift-guards on the verdict's SOURCE of truth. Comments are stripped first: the block explains
# WHY it is not `gc dolt health` / `gc dolt sql`, and that prose must not trip the guard.
WAIT_CODE="$(printf '%s\n' "$WAIT_BLOCK" | grep -v '^[[:space:]]*#' | sed 's/[[:space:]]#.*$//')"
# grep -c, not grep -q: this file runs under pipefail, and a -q that exits on its first match SIGPIPEs the
# printf — the pipeline then reads as "no match" and a guard that should FAIL passes (seen on the first run).
HITS_BAD=$(printf '%s\n' "$WAIT_CODE" | grep -Ec 'gc[[:space:]]+dolt[[:space:]]+(health|sql)') || HITS_BAD=0
if [ "$HITS_BAD" -gt 0 ]; then
  bad "ga-gs3bj3: the readiness verdict calls \`gc dolt health\` or \`gc dolt sql\` again (health is 13-40s under load; sql falls back to EMBEDDED mode and reads a dead Dolt as ready)"
else
  ok "ga-gs3bj3: the readiness verdict calls neither \`gc dolt health\` nor \`gc dolt sql\`"
fi
HITS_GOOD=$(printf '%s\n' "$WAIT_CODE" | grep -Ec 'timeout 5 dolt --host 127\.0\.0\.1 --port "\$_port" .*--no-tls sql -q .SELECT 1.') || HITS_GOOD=0
if [ "$HITS_GOOD" -ge 1 ]; then
  ok "ga-gs3bj3: the verdict probes the server directly (bounded 5s, explicit host/port, --no-tls — never the embedded path)"
else
  bad "ga-gs3bj3: the direct 'timeout 5 dolt --host 127.0.0.1 --port \$_port ... --no-tls sql -q SELECT 1' probe is gone from the verdict"
fi
has "$DISPATCHER" 'dolt-state\.json' "ga-gs3bj3: the port is read from the pack's runtime state file, not from an env var or a doc"
# the real call site: the wait sits INSIDE the retry loop block, between the backoff sleep and the re-spawn
if printf '%s\n' "$RETRY_BLOCK" | awk '/sleep "\$_spawn_backoff_secs"/{s=1} s&&/gate_spawn_wait_dolt_ready "\$i"/{w=1} w&&/session new gate-reviewer/{ok=1} END{exit !ok}'; then
  ok "ga-9e446u: the retry loop calls gate_spawn_wait_dolt_ready after the backoff sleep and before re-spawning"
else
  bad "ga-9e446u: gate_spawn_wait_dolt_ready is not wired between the backoff sleep and the re-spawn in the retry loop"
fi
has "$DISPATCHER" 'invalid connection.*read tcp.*broken pipe' "classifier still covers the live-incident signature family"
grep -q 'gate_spawn_failure_requeue_or_error "\$MARKER_ID" "\$_spawn_err"' "$DISPATCHER" \
  && ok "real call site wires MARKER_ID + _spawn_err into the decision function" \
  || bad "call site wiring not found — did the spawn-abort block get refactored again?"

# ga-ia7m7 drift-guards: atomic gate-status transition helper present and
# wired into both write sites it replaced (the "ready" write inside
# gate_spawn_failure_requeue_or_error, and the "error" write in the caller —
# the latter is also covered end-to-end by ERROR_WRITE_COUNT below).
has "$DISPATCHER" 'gate_status_transition\(\) \{' "gate_status_transition helper present (ga-ia7m7)"
has "$DISPATCHER" 'gate_status_transition "\$marker_id" "ready"' "ready-path wired through gate_status_transition, not a raw label add"

# gate-status:error must still be written exactly once in the abort block (the
# shared fallback for non-transient / cap-exhausted / unverified-write), not
# duplicated back into an early unconditional write the way it was pre-fix.
# ga-ia7m7: the raw `label add gate-status:error` this used to grep for is now
# a `gate_status_transition ... "error"` call (mutual-exclusion fix) — updated
# to match, same one-write-only intent.
ERROR_WRITE_COUNT=$(awk '
  /err "Failed to spawn reviewer session \$i/ { infn=1 }
  infn && /gate_status_transition "\$MARKER_ID" "error"/ { c++ }
  infn && /^  fi$/ { exit }
  END { print c+0 }
' "$DISPATCHER")
eq "gate-status:error written exactly once in the abort block (no early duplicate)" "$ERROR_WRITE_COUNT" "1"

# ga-ia7m7: the standalone `label remove gate-status:dispatching` that used to
# sit right after the "Aborting gate" log line, INSIDE THIS SPECIFIC abort
# block, is gone (folded into gate_status_transition's own full removal) —
# assert it's actually gone THERE, not just moved, so a future edit can't
# silently reintroduce the redundant early-remove-then-later-add-only-one
# window this fix closed. Scoped the same way as ERROR_WRITE_COUNT above
# (not a bare file-wide grep): this exact literal line legitimately still
# exists at ~12 OTHER, unrelated call sites elsewhere in this file.
DISPATCHING_REMOVE_IN_ABORT_BLOCK=$(awk '
  /err "Failed to spawn reviewer session \$i/ { infn=1 }
  infn && /label remove "\$MARKER_ID" "gate-status:dispatching"/ { c++ }
  infn && /^  fi$/ { exit }
  END { print c+0 }
' "$DISPATCHER")
eq "standalone dispatching-removal inside the ga-mzc3h abort block correctly removed (folded into gate_status_transition)" \
  "$DISPATCHING_REMOVE_IN_ABORT_BLOCK" "0"

CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
for fn in is_transient_spawn_error read_spawn_fail_count gate_spawn_failure_requeue_or_error gate_now_ms gate_dolt_ready_verdict gate_spawn_wait_dolt_ready; do
  DEF_LN=$(grep -n "^${fn}() {" "$DISPATCHER" | head -1 | cut -d: -f1)
  if [ -n "$DEF_LN" ] && [ -n "$CUTOFF_LN" ] && [ "$DEF_LN" -lt "$CUTOFF_LN" ]; then
    ok "$fn (line $DEF_LN) defined before the lib-only cutoff (line $CUTOFF_LN)"
  else
    bad "$fn must be defined before the GATE_DISPATCHER_LIB_ONLY cutoff (def=$DEF_LN cutoff=$CUTOFF_LN)"
  fi
done

# GATE_SPAWN_TRANSIENT_MAX_ATTEMPTS itself must ALSO resolve before the
# cutoff (ga-2u38b regression guard): gate_spawn_failure_requeue_or_error
# reads it directly (not as a parameter), so if a future edit moves the
# default assignment back below the cutoff, every LIB_ONLY/selftest
# invocation of the function crashes with "unbound variable" the instant it's
# actually called — exactly the bug this test tripped over while being
# written. type/declare -p can't distinguish "assigned before cutoff" from
# "assigned after", so assert on the OBSERVABLE behavior instead: the
# variable must already hold its default immediately after lib-only sourcing.
eq "GATE_SPAWN_TRANSIENT_MAX_ATTEMPTS resolves to its default under lib-only sourcing (not unbound)" "$GATE_SPAWN_TRANSIENT_MAX_ATTEMPTS" "3"

# gate-fix-4: the 6-call-site lesson from gate_marker_status_ensure — a stale
# "already logged inside the function" comment at any of THIS fix's call
# sites would mean the mute-by-construction discipline silently regressed.
# There is exactly one real call site (the spawn-abort block); assert it logs
# AFTER reading the token, not that the function logs internally.
has "$DISPATCHER" 'log "SUPPRESSED PUSH \(ga-2u38b non-terminal\)' "the one real call site logs after reading the ready/error token (caller-logs discipline)"

# ── 6. syntax ──────────────────────────────────────────────────────────────
echo "── 6. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
