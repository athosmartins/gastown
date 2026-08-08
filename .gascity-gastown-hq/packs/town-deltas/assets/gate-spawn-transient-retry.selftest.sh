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
# gate-marker-age-promote.selftest.sh) to prove the in-process retry actually
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
export -f is_transient_spawn_error

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
for fn in is_transient_spawn_error read_spawn_fail_count gate_spawn_failure_requeue_or_error; do
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
