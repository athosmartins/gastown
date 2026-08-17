#!/usr/bin/env bash
# gate-marker-status-selfheal.selftest.sh — ga-kgtiw mutation test.
#
# BUG (ga-kgtiw, found by batista-wa, amplified by the Mayor): every exit
# point in the dispatcher's rebase-fail path (Step 4c) removes gate-status:
# dispatching up front, then adds exactly one new terminal/requeue gate-status
# via a SEPARATE, unverified `bd label add ... || true` call. A silently-
# failed add (transient Dolt hiccup) leaves the marker with ZERO gate-status
# labels. That is not "parked" — every phase of this dispatcher selects its
# work via `bd ... -l gate-status:<value>`, so a marker with no such label
# matches no query, ever again. It vanishes permanently, no log, no alert.
# Measured live: 3/3 markers carrying gate:rebase-fail-count:1 had no
# gate-status label at all; one sat invisible for 3 days with 14 commits
# behind it. This is the SAME failure class ga-6dp9 already fixed for the
# gate:rebase-fail-count counter (gate_rebase_attempt_advanced) — falsify the
# write instead of assuming it — but that fix never covered the status label
# itself ([[error-and-empty-must-not-produce-the-same-value]]).
#
# FIX (two independent layers, per the bug's own CONSERTO):
#   (1) gate_marker_status_ensure(): called immediately before every exit
#       point in the rebase-fail path. Re-reads the marker's labels live and,
#       if truly empty, force-writes gate-status:error (safe, retriable) plus
#       a comment and a Mayor alert. The marker can never exit the script
#       invisible again.
#   (2) gate_bead_active_sibling_branch(): the one place in the dispatcher
#       that already walks every marker for a bead regardless of gate-status.
#       Its `[ -z "$status" ] && continue` used to skip an orphaned sibling in
#       total silence; it now emits an ALERT line to stderr first — a safety
#       net independent of fix (1), catching any marker that reaches this
#       broken state through a path this dispatcher version didn't anticipate.
#
# GATE-FIX-2 (gate_run=ga-wisp-0yhttsl FAILED, attempt 1/3): reviewer found
# gate_marker_status_ensure()'s repair path ended in `return 1`, called BARE
# (no if/&&/||/!) at all 6 call sites under this script's own
# `set -euo pipefail` — every time the self-heal actually fired, it aborted
# the ENTIRE dispatcher sweep right there, trading "one invisible marker" for
# "the whole sweep dies mid-repair". Also: the function's OWN verification
# read failing (bd show) was treated identically to "labels genuinely empty",
# risking a self-heal firing on an unverified marker and stacking a
# self-contradictory gate-status label onto one that may already be correct.
# Mayor's explicit guidance (not just the reviewer's): don't guard the 6 call
# sites (a 7th added later would forget the guard, replanting the bug
# identically) — make the FUNCTION always return 0 and signal via stdout
# ("ok" / "repaired" / "unknown"), mirroring gate_rebase_attempt_advanced(),
# so safety is a property of the function, not caller discipline. Also fixed:
# a read/parse failure now returns "unknown" and does NOT repair anything
# (previously conflated with "confirmed empty" via the same `|| echo ""`
# fallback). Mayor's additional AC: this selftest must call the function
# EXACTLY as the real call sites do — the OLD version of this file wrapped
# every call in `&& _RC=0 || _RC=$?` specifically to survive its own
# set -euo pipefail, a wrapper the 6 real call sites never carried; that
# divergence is why the test suite passed while the production wiring was
# broken. This version calls it the same way production does (stdout capture
# consumed via `[ "$(...)" = "token" ]`).
#
# GATE-FIX-3 (gate_run=ga-wisp-ub0uybc FAILED, attempt 2/3): reviewer found the
# "unknown" net itself had a gap — it inferred a failed `bd show` from EMPTY
# stdout, but the real `bd` binary exits 1 while still printing a non-empty
# JSON error object to stdout (`{"error": "...", "schema_version": 1}` — the
# human-readable message goes to stderr only). So a genuine read failure
# looked like a successful read of a marker with zero labels, and the
# function force-wrote gate-status:error plus a misleading "lost its status"
# Mayor alert onto a marker it never actually managed to read. Reviewer also
# flagged that case (e) below mocked the failure as a bare `return 1` with NO
# stdout — a shape the real binary never produces — so this very suite was
# green while the false-alert path was live. Fix: check bd's actual exit
# status from the command substitution directly instead of inferring it from
# stdout emptiness. Case (e)'s mock now matches bd's real on-error stdout;
# case (e2) covers the (unlikely but still handled) truly-empty-stdout shape
# the emptiness check still guards.
#
# GATE-FIX-4 (gate_run=ga-wisp-twg3gh8 FAILED, attempt 3/3, plus the Mayor's
# 2026-08-02 15:29 follow-up correcting the Mayor's own prior guidance): two
# independent blocking issues.
#   (1) gate_marker_status_ensure's warn()/err() calls used this script's own
#       log()/warn()/err() helpers, which write to STDOUT via plain `echo` —
#       not `>&2`. Every call site captures this function's output via
#       `$(...)`, so those calls polluted the captured token (e.g. "[ts] ...
#       ERROR: ga-kgtiw SELF-HEAL: ...\nrepaired" instead of the bare string
#       "repaired") — `= "repaired"` came out FALSE even when a repair
#       genuinely fired. THIS SUITE STAYED GREEN (57/57) THROUGH THAT BUG
#       because it stubbed log/warn/err to pure no-ops (see the comment right
#       above their definitions below, and the git history of this file) —
#       the mock was silent, so it could never demonstrate the pollution the
#       real helpers caused. Fixed by making the function MUTE (zero
#       log/warn/err calls in its body; the caller logs after reading the
#       signal, at the 6 real call sites) — and by this suite's log/warn/err
#       mocks now emitting a distinctive, unmistakable, non-empty marker
#       instead of true silence, so a regression would visibly corrupt the
#       captured token and fail the existing EXACT-match `eq()` assertions
#       below (a `contains`-style check would NOT have caught the original
#       bug: "repaired" is still a substring of the polluted value).
#   (2) the repair branch's `bd label add ... || true` — the write that
#       performs the actual fix — was never verified; a silently-failed write
#       left the function still printing 'repaired' and mailing the Mayor a
#       false "fixed it". Fixed by falsifying the write: a NEW post-write
#       re-read (factored into gate_marker_label_snapshot, shared with the
#       pre-write read so the two can never drift into different
#       error-detection rules) must CONFIRM the label landed before 'repaired'
#       is printed. Cases (c3)/(c4) below cover the write silently not taking
#       effect, and the post-write verification read itself failing — both
#       fall back to 'unknown' per the Mayor's 3-token contract
#       (ok/repaired/unknown), still mailing the Mayor but with honest
#       "could not confirm" wording rather than a false "fixed it".
#
# This harness SOURCES the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test gate_labels_have_status (pure) and gate_marker_status_ensure
# (bd/gc-backed, driven by in-shell mocks — NO live Dolt/gc/launchd), then
# extends the existing gate-sibling-branch-guard mock-bd harness to prove the
# stderr alert. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

for fn in gate_labels_have_status gate_marker_label_snapshot gate_marker_status_ensure gate_bead_active_sibling_branch; do
  type "$fn" >/dev/null 2>&1 \
    || { echo "FATAL: $fn not defined by dispatcher (ga-kgtiw fix missing?)"; exit 1; }
done

# gate-fix-4: log/warn/err are DELIBERATELY NOT stubbed to pure no-ops here.
# The gate-fix-2/3 version of this suite did exactly that ("Quiet logging
# noise... assertions below use the mock call counters, not log text") — and
# that silence is precisely why 57/57 assertions stayed green while
# gate_marker_status_ensure's real warn()/err() calls (this script's own
# helpers, plain `echo` to STDOUT, not `>&2`) were actively corrupting its
# captured return value in production (gate_run=ga-wisp-twg3gh8). These mocks
# instead emit a distinctive, unmistakable marker on every call: if
# gate_marker_status_ensure (or any future edit to it) ever calls one of
# these again, the marker glues itself onto the captured token and every
# EXACT-match `eq()` assertion below goes red. A `contains`-style check
# (`case "$CAPTURED" in *repaired*)`) would NOT have caught this — "repaired"
# is still a substring of "LOGCALL:err:...\nrepaired" — which is exactly the
# distinction the Mayor's gate-fix-4 AC called out.
log()  { printf 'LOGCALL:log:%s\n' "$*"; }
warn() { printf 'LOGCALL:warn:%s\n' "$*"; }
err()  { printf 'LOGCALL:err:%s\n' "$*"; }

# ── 1. gate_labels_have_status — pure predicate ───────────────────────────────
echo "── 1. gate_labels_have_status (pure) ──"
eq "empty labels → 0" \
  "$(gate_labels_have_status "")" "0"
eq "only unrelated labels → 0" \
  "$(gate_labels_have_status "type:quality-gate-marker source-bead:wa-x branch:crew/me/wa-x")" "0"
eq "gate-status present among others → 1" \
  "$(gate_labels_have_status "type:quality-gate-marker gate-status:queued source-bead:wa-x")" "1"
eq "gate-status alone → 1" \
  "$(gate_labels_have_status "gate-status:error")" "1"
eq "near-miss (not anchored, e.g. a rig label containing the substring) → 0" \
  "$(gate_labels_have_status "area:not-gate-status:foo")" "0"
eq "gate-status with empty value still counts as present → 1" \
  "$(gate_labels_have_status "gate-status:")" "1"

# ── 2. gate_marker_status_ensure — bd/gc-backed self-heal (mock bd + gc) ──────
echo "── 2. gate_marker_status_ensure (bd show/label/comment + gc mail, mock bd+gc) ──"
MOCK_SHOW_JSON='[]'
MOCK_LABEL_ADD_COUNT=0
MOCK_LABEL_ADD_LAST=""
MOCK_COMMENT_COUNT=0
MOCK_MAIL_COUNT=0
MOCK_MAIL_LAST=""

bd() {
  case " $* " in
    *" show "*)
      printf '%s\n' "$MOCK_SHOW_JSON"
      ;;
    *" label add "*)
      MOCK_LABEL_ADD_COUNT=$((MOCK_LABEL_ADD_COUNT + 1))
      MOCK_LABEL_ADD_LAST="$*"
      ;;
    *" comment "*)
      MOCK_COMMENT_COUNT=$((MOCK_COMMENT_COUNT + 1))
      ;;
    *) : ;;
  esac
  return 0
}
gc() {
  case " $* " in
    *" mail send "*)
      MOCK_MAIL_COUNT=$((MOCK_MAIL_COUNT + 1))
      MOCK_MAIL_LAST="$*"
      ;;
    *) : ;;
  esac
  return 0
}

# Calling convention below matches the 6 real call sites exactly (gate-fix-2
# AC): stdout is consumed the same way production consumes it — via a
# command-substitution capture of the token — never via a defensive &&/||
# exit-code wrapper the production code doesn't also use. Safe under this
# test's own `set -euo pipefail` purely because the function itself never
# returns non-zero anymore — the same property the production call sites now
# lean on.
#
# gate-fix-2 subtlety: `$(gate_marker_status_ensure ...)` forks a SUBSHELL in
# bash, so any MOCK_* counter increment made by the mocked bd()/gc() during
# that call is invisible once the subshell exits — the exact kind of
# error/empty-conflation this whole bug is about, just one layer up in the
# test harness itself. _capture_out below redirects stdout to a file INSTEAD
# of substituting it, so the mocked call runs in THIS shell and counter
# side effects survive; it still can't fail the script under set -e (the
# `&&`/`||` pair is in the exempt list-position, same reasoning as production).
_capture_out() {
  local __tmp
  __tmp=$(mktemp)
  "$@" >"$__tmp" && CAPTURED_RC=0 || CAPTURED_RC=$?
  CAPTURED=$(cat "$__tmp")
  rm -f "$__tmp"
}

# (a) empty marker_id → no-op "ok", never touches bd/gc.
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
_capture_out gate_marker_status_ensure '' 'test context'
eq "(a) empty marker_id → return 0" "$CAPTURED_RC" "0"
eq "(a) empty marker_id → stdout 'ok'" "$CAPTURED" "ok"
eq "(a) empty marker_id → bd label add never called" "$MOCK_LABEL_ADD_COUNT" "0"
eq "(a) empty marker_id → gc mail send never called" "$MOCK_MAIL_COUNT" "0"

# (b) marker already carries a gate-status → fast path "ok", no repair, no mail.
MOCK_SHOW_JSON='[{"id":"m1","labels":["gate-status:queued","source-bead:wa-x"]}]'
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
_capture_out gate_marker_status_ensure 'm1' 'test context'
eq "(b) status present → return 0" "$CAPTURED_RC" "0"
eq "(b) status present → stdout 'ok' (healthy, no repair)" "$CAPTURED" "ok"
eq "(b) status present → bd label add NOT called" "$MOCK_LABEL_ADD_COUNT" "0"
eq "(b) status present → bd comment NOT called" "$MOCK_COMMENT_COUNT" "0"
eq "(b) status present → gc mail send NOT called (no spam on the healthy path)" "$MOCK_MAIL_COUNT" "0"

# (c) THE BUG: marker has labels but NO gate-status → self-heal fires, and
# the function still returns 0 (gate-fix-2: never abort the sweep). The mock
# is STATEFUL (gate-fix-4): a real `bd label add` would change what a
# subsequent `bd show` returns, and this function now re-reads after its own
# write to verify it (blocking issue 2, gate_run=ga-wisp-twg3gh8) — a mock
# that never changes MOCK_SHOW_JSON would make every successful repair
# misread as a failed one.
MOCK_SHOW_JSON='[{"id":"m2","labels":["source-bead:wa-x","branch:crew/me/wa-x"]}]'
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *" label add "*)
      MOCK_LABEL_ADD_COUNT=$((MOCK_LABEL_ADD_COUNT + 1))
      MOCK_LABEL_ADD_LAST="$*"
      MOCK_SHOW_JSON='[{"id":"m2","labels":["source-bead:wa-x","branch:crew/me/wa-x","gate-status:error"]}]'
      ;;
    *" comment "*)
      MOCK_COMMENT_COUNT=$((MOCK_COMMENT_COUNT + 1))
      MOCK_COMMENT_LAST="$*"
      ;;
    *) : ;;
  esac
  return 0
}
_capture_out gate_marker_status_ensure 'm2' 'the transient-retry queue write'
eq "(c) status missing, write verified → return 0 even though it repaired (gate-fix-2)" "$CAPTURED_RC" "0"
eq "(c) status missing, write verified → stdout 'repaired' (caller tells via stdout, not exit code)" "$CAPTURED" "repaired"
eq "(c) status missing, write verified → bd label add called exactly once" "$MOCK_LABEL_ADD_COUNT" "1"
case "$MOCK_LABEL_ADD_LAST" in
  *"m2"*"gate-status:error"*) ok "(c) repair wrote gate-status:error onto the right marker" ;;
  *) bad "(c) expected label add m2 gate-status:error, got: $MOCK_LABEL_ADD_LAST" ;;
esac
eq "(c) status missing, write verified → bd comment called exactly once (durable trail on the marker)" "$MOCK_COMMENT_COUNT" "1"
eq "(c) status missing, write verified → gc mail send called exactly once (Mayor alerted)" "$MOCK_MAIL_COUNT" "1"
case "$MOCK_MAIL_LAST" in
  *"mayor"*"m2"*) ok "(c) mail addressed to mayor, names the marker" ;;
  *) bad "(c) expected mail to mayor naming m2, got: $MOCK_MAIL_LAST" ;;
esac

# (c2) gate-fix-2 regression guard, empirically reproducing the reviewer's own
# repro shape: call the function completely BARE (no if/$()/&&) exactly like
# all 6 real call sites used to, immediately followed by another statement.
# Under set -euo pipefail, attempt-1's `return 1` on this exact path aborted
# the whole script here — this line never running would mean the FAIL (the
# script would die above without ever reaching the PASS/FAIL tally at the end).
# Fresh, independent mock (not carried over from (c)): (c)'s mock left
# MOCK_SHOW_JSON mutated to already carry gate-status:error, which would
# short-circuit this marker onto the "ok" fast path and never even reach the
# repair code this case exists to exercise.
MOCK_SHOW_JSON='[{"id":"m2b","labels":["source-bead:wa-x"]}]'
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *" label add "*)
      MOCK_LABEL_ADD_COUNT=$((MOCK_LABEL_ADD_COUNT + 1))
      MOCK_SHOW_JSON='[{"id":"m2b","labels":["source-bead:wa-x","gate-status:error"]}]'
      ;;
    *" comment "*) MOCK_COMMENT_COUNT=$((MOCK_COMMENT_COUNT + 1)) ;;
    *) : ;;
  esac
  return 0
}
gate_marker_status_ensure 'm2b' 'bare-call regression guard' >/dev/null
ok "(c2) bare (unguarded) call on the repair path did NOT abort the script under set -euo pipefail"

# (c3) gate-fix-4 (reviewer blocking issue 2 on gate_run=ga-wisp-twg3gh8): the
# label-add write is accepted but does NOT change the marker's actual labels
# — simulating the exact transient-Dolt-write failure this bug was originally
# measured with live (3/3 markers). The post-write verification re-read must
# catch this and refuse to claim 'repaired', falling back to 'unknown' (the
# Mayor's contract names exactly three tokens — ok/repaired/unknown — so an
# unconfirmed repair does not get a token of its own). Mail must still fire
# (human-in-the-loop fallback) but must NOT claim the marker is fixed.
MOCK_SHOW_JSON='[{"id":"m2c","labels":["source-bead:wa-x"]}]'
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *" label add "*) MOCK_LABEL_ADD_COUNT=$((MOCK_LABEL_ADD_COUNT + 1)) ;;  # accepted, MOCK_SHOW_JSON deliberately left unchanged
    *" comment "*) MOCK_COMMENT_COUNT=$((MOCK_COMMENT_COUNT + 1)) ;;
    *) : ;;
  esac
  return 0
}
_capture_out gate_marker_status_ensure 'm2c' 'the transient-retry queue write'
eq "(c3) repair write does not take effect → return 0 (never aborts the sweep)" "$CAPTURED_RC" "0"
eq "(c3) repair write does not take effect → stdout 'unknown', NOT falsely 'repaired'" "$CAPTURED" "unknown"
eq "(c3) repair write does not take effect → bd label add was still attempted once" "$MOCK_LABEL_ADD_COUNT" "1"
eq "(c3) repair write does not take effect → still comments (audit trail) even though unconfirmed" "$MOCK_COMMENT_COUNT" "1"
eq "(c3) repair write does not take effect → still mails the Mayor (human-in-the-loop fallback)" "$MOCK_MAIL_COUNT" "1"
case "$MOCK_MAIL_LAST" in
  *"m2c"*) ok "(c3) mail names the marker m2c" ;;
  *) bad "(c3) expected mail naming m2c, got: $MOCK_MAIL_LAST" ;;
esac
# Positive check, not a substring-absence check: "not fixed" legitimately
# contains "fixed" as a substring (a `*fixed*` exclusion would itself be the
# exact naive-substring mistake this whole bug saga is about), so assert the
# HONEST wording is present rather than trying to prove a negative.
case "$MOCK_MAIL_LAST" in
  *"could NOT confirm"*|*"could NOT verify"*) ok "(c3) mail honestly states the repair could not be confirmed, not a false 'fixed it'" ;;
  *) bad "(c3) expected honest could-not-confirm/verify wording, got: $MOCK_MAIL_LAST" ;;
esac

# (c4) gate-fix-4: the SECOND (post-write verification) read itself fails —
# must be 'unknown', never misread as either a confirmed fix or a confirmed
# ongoing failure. Same [[error-and-empty-must-not-produce-the-same-value]]
# class this whole bug is about, one layer further down: a failed
# verification read is genuinely indeterminate, distinct from a verification
# read that succeeds and shows the label still missing (c3, above) — both
# happen to map to the same 'unknown' token, but for different, non-conflated
# reasons internally.
MOCK_SHOW_JSON='[{"id":"m2d","labels":["source-bead:wa-x"]}]'
MOCK_SHOW_CALL_COUNT=0
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
bd() {
  case " $* " in
    *" show "*)
      MOCK_SHOW_CALL_COUNT=$((MOCK_SHOW_CALL_COUNT + 1))
      if [ "$MOCK_SHOW_CALL_COUNT" -eq 1 ]; then
        printf '%s\n' "$MOCK_SHOW_JSON"
      else
        printf '%s\n' '{"error": "no issues found matching the provided IDs", "schema_version": 1}'
        return 1
      fi
      ;;
    *" label add "*) MOCK_LABEL_ADD_COUNT=$((MOCK_LABEL_ADD_COUNT + 1)) ;;
    *" comment "*) MOCK_COMMENT_COUNT=$((MOCK_COMMENT_COUNT + 1)) ;;
    *) : ;;
  esac
  return 0
}
_capture_out gate_marker_status_ensure 'm2d' 'test context'
eq "(c4) post-write verification read itself fails → return 0" "$CAPTURED_RC" "0"
eq "(c4) post-write verification read itself fails → stdout 'unknown'" "$CAPTURED" "unknown"
eq "(c4) post-write verification read itself fails → bd label add was still attempted once" "$MOCK_LABEL_ADD_COUNT" "1"
eq "(c4) post-write verification read itself fails → still mails the Mayor (can't confirm either way)" "$MOCK_MAIL_COUNT" "1"

# (d) marker JSON returned as a bare object (not array) — same shape gate_bead_live_merge_block tolerates.
# Own explicit mock (not the (c4) leftover): (c4)'s bd() keys behavior off a
# call counter that would otherwise still be primed from (c4)'s two calls,
# misrouting this case's single call into (c4)'s injected-failure branch.
MOCK_SHOW_JSON='{"id":"m3","labels":["gate-status:running"]}'
MOCK_LABEL_ADD_COUNT=0; MOCK_MAIL_COUNT=0
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *" label add "*) MOCK_LABEL_ADD_COUNT=$((MOCK_LABEL_ADD_COUNT + 1)) ;;
    *) : ;;
  esac
  return 0
}
_capture_out gate_marker_status_ensure 'm3' 'test context'
eq "(d) bare-object show JSON, status present → return 0" "$CAPTURED_RC" "0"
eq "(d) bare-object show JSON, status present → stdout 'ok', no repair" "$CAPTURED" "ok"
eq "(d) bare-object show JSON, status present → no label add" "$MOCK_LABEL_ADD_COUNT" "0"

# (e) bd show fails exactly as the REAL bd binary does it (gate-fix-3 repro,
# gate_run=ga-wisp-ub0uybc): exits 1 but still writes a non-empty, valid JSON
# error object to STDOUT (`{"error": ..., "schema_version": 1}` — the human-
# readable message goes to stderr only). Must still be "unknown", NOT treated
# as confirmed-empty. Blocking issue 2 from gate_run=ga-wisp-0yhttsl, reopened
# by ga-wisp-ub0uybc via this exact non-empty-stdout shape: conflating this
# function's OWN read failure with "labels are genuinely empty" could stack a
# self-contradictory gate-status:error onto a marker whose earlier branch-
# specific write may have actually succeeded — and mail the Mayor a
# misleading "lost its status" alert pointing at the wrong root cause. An
# unverifiable marker must NOT be repaired; it stays untouched and gets
# picked up again whenever a future read succeeds.
bd() {
  case " $* " in
    *" show "*) printf '%s\n' '{"error": "no issues found matching the provided IDs", "schema_version": 1}'; return 1 ;;
    *" label add "*) MOCK_LABEL_ADD_COUNT=$((MOCK_LABEL_ADD_COUNT + 1)) ;;
    *" comment "*) MOCK_COMMENT_COUNT=$((MOCK_COMMENT_COUNT + 1)) ;;
    *) : ;;
  esac
  return 0
}
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
_capture_out gate_marker_status_ensure 'm4' 'test context'
eq "(e) bd show exits 1 with non-empty stdout → return 0 (never aborts the sweep)" "$CAPTURED_RC" "0"
eq "(e) bd show exits 1 with non-empty stdout → stdout 'unknown', not misread as confirmed-empty (gate-fix-3)" "$CAPTURED" "unknown"
eq "(e) bd show exits 1 with non-empty stdout → does NOT force-write gate-status:error" "$MOCK_LABEL_ADD_COUNT" "0"
eq "(e) bd show exits 1 with non-empty stdout → does NOT comment on the marker" "$MOCK_COMMENT_COUNT" "0"
eq "(e) bd show exits 1 with non-empty stdout → does NOT mail the Mayor (no misleading alert)" "$MOCK_MAIL_COUNT" "0"

# (e2) degenerate case the belt-and-suspenders emptiness check still guards:
# bd show exits 0 but stdout is truly empty. Distinct from (e), which tests
# exit-status detection alone with realistic non-empty error stdout; this
# confirms the `[ -z "$raw" ]` check after it still catches a genuinely empty
# "successful" read instead of letting it fall through to jq.
bd() {
  case " $* " in
    *" show "*) printf '' ;;
    *" label add "*) MOCK_LABEL_ADD_COUNT=$((MOCK_LABEL_ADD_COUNT + 1)) ;;
    *" comment "*) MOCK_COMMENT_COUNT=$((MOCK_COMMENT_COUNT + 1)) ;;
    *) : ;;
  esac
  return 0
}
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
_capture_out gate_marker_status_ensure 'm4b' 'test context'
eq "(e2) bd show exits 0 with truly empty stdout → return 0" "$CAPTURED_RC" "0"
eq "(e2) bd show exits 0 with truly empty stdout → stdout 'unknown'" "$CAPTURED" "unknown"
eq "(e2) bd show exits 0 with truly empty stdout → does NOT force-write gate-status:error" "$MOCK_LABEL_ADD_COUNT" "0"

# (f) bd show succeeds but returns unparseable JSON → same "unknown" treatment
# as a read failure (blocking issue 2 applies equally to a parse failure).
MOCK_SHOW_JSON='not valid json{{{'
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *" label add "*) MOCK_LABEL_ADD_COUNT=$((MOCK_LABEL_ADD_COUNT + 1)) ;;
    *" comment "*) MOCK_COMMENT_COUNT=$((MOCK_COMMENT_COUNT + 1)) ;;
    *) : ;;
  esac
  return 0
}
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
_capture_out gate_marker_status_ensure 'm5' 'test context'
eq "(f) unparseable show JSON → return 0 (never aborts the sweep)" "$CAPTURED_RC" "0"
eq "(f) unparseable show JSON → stdout 'unknown'" "$CAPTURED" "unknown"
eq "(f) unparseable show JSON → does NOT force-write gate-status:error" "$MOCK_LABEL_ADD_COUNT" "0"
eq "(f) unparseable show JSON → does NOT mail the Mayor" "$MOCK_MAIL_COUNT" "0"

# ── 3. gate_bead_active_sibling_branch — orphaned sibling now ALERTS, never silently vanishes ──
echo "── 3. gate_bead_active_sibling_branch: no-status sibling logs to stderr, genuine sibling still found ──"
bd() {
  case " $* " in
    *" list "*) printf '%s\n' "$MOCK_LIST_JSON" ;;
    *) : ;;
  esac
  return 0
}

STDERR_FILE=$(mktemp)
cleanup_stderr_file() { rm -f "$STDERR_FILE"; }
trap cleanup_stderr_file EXIT

# (a) ONLY a broken (no gate-status) sibling present.
MOCK_LIST_JSON='[{"id":"m-orphan","status":"open","labels":["source-bead:wa-kgtiw-test","branch:crew/ghost/wa-kgtiw-test"],"description":""}]'
: > "$STDERR_FILE"
RESULT=$(gate_bead_active_sibling_branch city 'wa-kgtiw-test' 'crew/me/wa-kgtiw-test' 2>"$STDERR_FILE")
eq "(a) only an orphaned no-status sibling → '' (unchanged external contract)" "$RESULT" ""
if grep -q "ALERT" "$STDERR_FILE" && grep -q "m-orphan" "$STDERR_FILE" && grep -q "gate-status" "$STDERR_FILE"; then
  ok "(a) orphaned sibling produced a stderr ALERT naming the marker (ga-kgtiw safety net fired)"
else
  bad "(a) expected a stderr ALERT naming m-orphan and gate-status, got: $(cat "$STDERR_FILE")"
fi

# (b) a broken sibling AND a genuine active sibling together — the orphan must
# not swallow or short-circuit detection of the real one.
MOCK_LIST_JSON='[{"id":"m-orphan","status":"open","labels":["source-bead:wa-kgtiw-test","branch:crew/ghost/wa-kgtiw-test"],"description":""},{"id":"m-real","status":"open","labels":["gate-status:running","source-bead:wa-kgtiw-test","branch:crew/oracle/wa-kgtiw-test"],"description":""}]'
: > "$STDERR_FILE"
RESULT=$(gate_bead_active_sibling_branch city 'wa-kgtiw-test' 'crew/me/wa-kgtiw-test' 2>"$STDERR_FILE")
eq "(b) orphan + genuine sibling → genuine one still found" "$RESULT" "$(printf 'crew/oracle/wa-kgtiw-test\trunning')"
if grep -q "m-orphan" "$STDERR_FILE"; then
  ok "(b) orphan still alerted even though a real sibling was also present"
else
  bad "(b) expected an alert mentioning m-orphan, got: $(cat "$STDERR_FILE")"
fi

# (c) no orphan at all → no stderr output (no false alarms on the healthy path).
MOCK_LIST_JSON='[{"id":"m-real","status":"open","labels":["gate-status:running","source-bead:wa-kgtiw-test","branch:crew/oracle/wa-kgtiw-test"],"description":""}]'
: > "$STDERR_FILE"
RESULT=$(gate_bead_active_sibling_branch city 'wa-kgtiw-test' 'crew/me/wa-kgtiw-test' 2>"$STDERR_FILE")
eq "(c) healthy sibling only → still found" "$RESULT" "$(printf 'crew/oracle/wa-kgtiw-test\trunning')"
if [ -s "$STDERR_FILE" ]; then
  bad "(c) expected NO stderr output on the healthy path, got: $(cat "$STDERR_FILE")"
else
  ok "(c) no false-alarm stderr output when every sibling has a status"
fi

cleanup_stderr_file
trap - EXIT

# ── 4. Drift guard: gate_marker_status_ensure wired at every rebase-fail exit ─
echo "── 4. drift guard: self-heal called before every rebase-fail exit point ──"
CALL_COUNT=$(grep -c 'gate_marker_status_ensure "\$MARKER_ID"' "$DISPATCHER")
eq "gate_marker_status_ensure called exactly 8 times (one per rebase-fail exit point)" "$CALL_COUNT" "8"

for context in \
  "the main-ref-unresolvable guard" \
  "the merge-tree-undeterminable guard" \
  "the ahead_dead circuit-break" \
  "the behind_dead circuit-break" \
  "the behind-envelope bounce" \
  "the behind-envelope owner-fallback bounce" \
  "the pool-author rebase return" \
  "the auto-rebase decision \(merge-conflict/transient-retry/circuit-break\)"; do
  has "$DISPATCHER" "gate_marker_status_ensure \"\\\$MARKER_ID\" \"${context}\"" \
    "self-heal wired at: ${context}"
done

# ── 4b. gate-fix-2 regression guard: no call site may be bare, and the
# function must never return non-zero on its repair path ─────────────────────
echo "── 4b. gate-fix-2: call sites consume via if/\$(), function never return-1s ──"
# NOTE (self-referential lesson): `grep -c` prints "0" but still EXITS 1 when
# it legitimately finds zero matches — the exact expected outcome for both
# checks below. A bare `VAR=$(grep -c ...)` assignment under this script's own
# set -e would abort right here on the PASSING case, the same error/empty
# conflation this whole bug is about, one layer up in the harness. `|| true`
# on the grep, not on the assignment, so a real grep ERROR (exit 2) still
# leaves CAPTURED empty and the eq below correctly reports FAIL, not a
# silent pass.
BARE_CALL_COUNT=$(grep -cE '^\s*gate_marker_status_ensure "\$MARKER_ID"' "$DISPATCHER" || true)
eq "zero call sites invoke gate_marker_status_ensure as a bare statement" "$BARE_CALL_COUNT" "0"

WRAPPED_CALL_COUNT=$(grep -cE 'if \[ "\$\(gate_marker_status_ensure "\$MARKER_ID"' "$DISPATCHER" || true)
eq "all 8 call sites consume via if [ \"\$(gate_marker_status_ensure ...)\" = ... ]" "$WRAPPED_CALL_COUNT" "8"

FN_BODY_START=$(grep -n '^gate_marker_status_ensure() {' "$DISPATCHER" | head -1 | cut -d: -f1)
FN_BODY_END=$(awk -v start="$FN_BODY_START" 'NR>start && /^}/ {print NR; exit}' "$DISPATCHER")
if [ -n "$FN_BODY_START" ] && [ -n "$FN_BODY_END" ]; then
  RETURN1_COUNT=$(sed -n "${FN_BODY_START},${FN_BODY_END}p" "$DISPATCHER" | grep -cE 'return 1\b' || true)
  eq "gate_marker_status_ensure body contains zero 'return 1' (always returns 0)" "$RETURN1_COUNT" "0"

  # gate-fix-4 (blocking issue 1, gate_run=ga-wisp-twg3gh8): the function must
  # stay MUTE — zero log/warn/err calls anywhere in its body — since its
  # stdout is captured via $(...) by every call site. Comment-only lines are
  # excluded first so the extensive gate-fix-4 documentation ABOVE the
  # function (which necessarily talks ABOUT log/warn/err in prose) can't
  # false-positive this check; only lines that survive as actual code are
  # searched for real call syntax (bare word + whitespace + open-quote).
  LOGCALL_COUNT=$(sed -n "${FN_BODY_START},${FN_BODY_END}p" "$DISPATCHER" \
    | grep -v '^\s*#' \
    | grep -cE '(^|[^a-zA-Z0-9_])(log|warn|err)[[:space:]]+"' || true)
  eq "gate_marker_status_ensure body contains zero log/warn/err calls (mute by construction, gate-fix-4)" "$LOGCALL_COUNT" "0"
else
  bad "could not locate gate_marker_status_ensure function body bounds (start=$FN_BODY_START end=$FN_BODY_END)"
fi

CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
for fn in gate_labels_have_status gate_marker_label_snapshot gate_marker_status_ensure; do
  DEF_LN=$(grep -n "^${fn}() {" "$DISPATCHER" | head -1 | cut -d: -f1)
  if [ -n "$DEF_LN" ] && [ -n "$CUTOFF_LN" ] && [ "$DEF_LN" -lt "$CUTOFF_LN" ]; then
    ok "$fn (line $DEF_LN) defined before the lib-only cutoff (line $CUTOFF_LN)"
  else
    bad "$fn must be defined before the GATE_DISPATCHER_LIB_ONLY cutoff (def=$DEF_LN cutoff=$CUTOFF_LN)"
  fi
done

# gate-fix-4: the 6 call sites must actually log on "repaired" now that the
# function itself is mute — the STALE "already logged... inside
# gate_marker_status_ensure" no-op comment would mean the self-heal event
# never reaches this dispatcher's own log stream at all (mail + bd comment
# still fire from inside the function, but that's a different, out-of-band
# channel — see gate-fix-4 docstring).
STALE_NOOP_COUNT=$(grep -cF 'already logged, commented, and mailed inside gate_marker_status_ensure' "$DISPATCHER" || true)
eq "zero call sites still carry the stale gate-fix-3-era 'already logged inside' no-op comment" "$STALE_NOOP_COUNT" "0"

CALLER_LOG_COUNT=$(grep -cE '(log|warn|err) "ga-kgtiw SELF-HEAL: marker \$MARKER_ID had no gate-status label after' "$DISPATCHER" || true)
eq "all 8 call sites log on a 'repaired' outcome (caller logs after reading the signal, gate-fix-4)" "$CALLER_LOG_COUNT" "8"

# ── 5. syntax ──────────────────────────────────────────────────────────────
echo "── 5. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
