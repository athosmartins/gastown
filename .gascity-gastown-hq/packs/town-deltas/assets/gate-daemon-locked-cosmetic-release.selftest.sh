#!/usr/bin/env bash
# gate-daemon-locked-cosmetic-release.selftest.sh — ga-j3lh6p, the class sweep's
# SECOND consumer (story-delivery.sh Step 5b is the first; see
# tests/story-delivery-locked-cosmetic-release.test.sh).
#
# THE DEFECT CLASS: quality-gate-dispatcher.sh's ga-l7n3v daemon-verification
# holds a merged bug/task bead as delivery:pending-restart on ANY verdict that is
# not OK/SKIPPED — and it reads only VERDICT/REASON/PROOF, never GUARDED or the
# symbol split. A bug/task whose merge touches a lib imported by a
# notify_only_locked daemon (com.whatsapp.demand-dashboard: "Trava humana: NUNCA
# auto", a restart halts the outreach worker it hosts) is therefore held for a
# daemon NO automation can ever restart. merged-bead-janitor.sh guards that label,
# so nothing releases it — it stays open until somebody closes it by hand (the
# exact cost wa-z66jb / wa-ho1ol paid on the story-delivery side, 20/09).
#
# daemon-refresh.sh (header point 19) now names, in GUARDED_LOCKED_COSMETIC, the
# GUARDED subset that is BOTH locked against automation AND cleanly evaluated to
# "no call-graph path to any symbol this merge changed". This file pins how the
# dispatcher consumes it:
#
#   U*  daemon_refresh_locked_cosmetic_release — the one decision function.
#       Release ONLY when the verdict is exactly NEEDS_GUARDED_RESTART, GUARDED is
#       non-empty, the helper printed the GUARDED_LOCKED_COSMETIC line at all, AND
#       every GUARDED label is named there. Positive membership per label; a
#       missing line, an empty one, a mixed set, another verdict, or a name that is
#       not stale all mean HOLD (absent != empty != covered).
#   W*  the REAL extracted `case "$DR_VERDICT"` block (SELFTEST-EXTRACT
#       daemon-refresh-verdict-case): a release must not set the hold, must record
#       the evidence on the bead, and must select the delivery:daemon-stale-locked
#       label — while every other verdict still holds exactly as before.
#   C*  the REAL extracted close snippet (SELFTEST-EXTRACT daemon-soft-warn-close):
#       the label and the close-reason wording follow DAEMON_SOFT_WARN_LABEL, and
#       the pre-existing "not positively confirmed" path is byte-for-byte unchanged.
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
# has <haystack> <needle> — literal substring test with NO pipe (pipefail + grep -q
# on a multi-KB variable is a SIGPIPE race; see story-delivery-locked-cosmetic-
# release.test.sh for the measurement).
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

echo "== gate-daemon-locked-cosmetic-release.selftest (ga-j3lh6p) =="

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

TMP="$(mktemp -d)"
BD_LOG="$TMP/bd.log"
: > "$BD_LOG"
trap 'rm -rf "$TMP"' EXIT
# Override AFTER sourcing: the lib's own log/warn/bd/gc must not touch anything real.
bd()   { echo "bd $*" >> "$BD_LOG"; }
gc()   { echo "gc $*" >> "$BD_LOG"; }
warn() { :; }
log()  { :; }

extract() { sed -n "/# SELFTEST-EXTRACT $1: BEGIN/,/# SELFTEST-EXTRACT $1: END/p" "$DISPATCHER"; }

LOCKED="com.test.demand-dashboard"
PLAIN="com.test.plain-daemon"

# mk_out <verdict> <guarded> <cosmetic|ABSENT> — the KEY=value lines daemon-refresh.sh
# prints. daemon-refresh.sh's stderr is merged into the dispatcher's DR_OUT (2>&1), so
# a noise line that merely CONTAINS a key mid-line is added on purpose.
mk_out() {
  local v="$1" g="$2" c="$3"
  printf '[2026-09-20 13:00:00] daemon-refresh: saw GUARDED=%s and GUARDED_LOCKED_COSMETIC=%s in a log line\n' "noise" "noise"
  printf 'VERDICT=%s\nALL_LABELS=\nAFFECTED=%s\nRESTARTED=\nFRESH_FAIL=\nGUARDED=%s\nGUARDED_OWN=\nGUARDED_CLOSURE_ONLY=%s\n' "$v" "$g" "$g" "$g"
  if [ "$c" != "ABSENT" ]; then printf 'GUARDED_LOCKED_COSMETIC=%s\n' "$c"; fi
  printf 'REASON=canned reason\nPROOF=not_verified\n'
}

# ── U: the decision function ────────────────────────────────────────────────
echo "── U. daemon_refresh_locked_cosmetic_release ──"
# The W/C sections below run either way, so a missing function is reported as ONE
# failure here without hiding the behavioural failures that follow it.
run_u_tests() {
release() { local out; out="$(mk_out "$1" "$2" "$3")"; RELEASED="$(daemon_refresh_locked_cosmetic_release "$out")" && RC=0 || RC=$?; }

release NEEDS_GUARDED_RESTART "$LOCKED" "$LOCKED"
[ "$RC" -eq 0 ] && [ "$RELEASED" = "$LOCKED" ] && ok "U1 locked + cosmetic -> released, and it names the covered label" || bad "U1 rc=$RC out='$RELEASED'"
release NEEDS_GUARDED_RESTART "$LOCKED" ""
[ "$RC" -ne 0 ] && ok "U2 GUARDED_LOCKED_COSMETIC present but EMPTY (CONFIRMED / NOT_COMPUTED / not locked) -> HOLD" || bad "U2 released on an empty cosmetic set"
release NEEDS_GUARDED_RESTART "$LOCKED" ABSENT
[ "$RC" -ne 0 ] && ok "U3 a helper that predates the field (NO line) -> HOLD (absent != empty)" || bad "U3 released though the helper never said anything about cosmetic"
release NEEDS_GUARDED_RESTART "$LOCKED $PLAIN" "$LOCKED"
[ "$RC" -ne 0 ] && ok "U4 mixed: one locked+cosmetic AND one ordinary stale daemon -> HOLD (the ordinary one is real work)" || bad "U4 released with an ordinary daemon still stale"
release JOB_NOT_INSTALLED "$LOCKED" "$LOCKED"
[ "$RC" -ne 0 ] && ok "U5 JOB_NOT_INSTALLED carrying a cosmetic line -> HOLD (a job that never ran is not excused by the split)" || bad "U5 released on a non-NEEDS_GUARDED_RESTART verdict"
release NEEDS_GUARDED_RESTART "$LOCKED" "com.test.some-other-daemon"
[ "$RC" -ne 0 ] && ok "U6 the cosmetic line names a DIFFERENT label -> HOLD (every stale label must be covered, by name)" || bad "U6 released though the stale label is not in the cosmetic set"
release NEEDS_GUARDED_RESTART "" ""
[ "$RC" -ne 0 ] && ok "U7 NEEDS_GUARDED_RESTART with an EMPTY GUARDED -> HOLD (nothing to release is not a release)" || bad "U7 released on an empty GUARDED"
release NEEDS_GUARDED_RESTART "$LOCKED" "$PLAIN $LOCKED"
[ "$RC" -eq 0 ] && [ "$RELEASED" = "$LOCKED" ] && ok "U8 a cosmetic set that is a superset of GUARDED still covers it" || bad "U8 rc=$RC out='$RELEASED'"
out="$(mk_out NEEDS_GUARDED_RESTART "$LOCKED" "$LOCKED")"; out="$out"$'\n'"VERDICT=VERIFY_FAILED"
RELEASED="$(daemon_refresh_locked_cosmetic_release "$out")" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && ok "U9 only the FIRST VERDICT= line counts (same head -1 rule as the dispatcher's own parse)" || bad "U9 rc=$RC"
}
if declare -F daemon_refresh_locked_cosmetic_release >/dev/null 2>&1; then
  run_u_tests
else
  bad "U0 daemon_refresh_locked_cosmetic_release is not defined in the dispatcher (the feature is missing)"
fi

# ── W: the real extracted case block ────────────────────────────────────────
echo "── W. daemon-refresh-verdict-case (live extraction via sentinel) ──"
CASE_BLOCK="$(extract daemon-refresh-verdict-case)"
[ -n "$CASE_BLOCK" ] || { echo "FATAL: sentinel daemon-refresh-verdict-case not found in $DISPATCHER"; exit 1; }
ok "located the live verdict case block via sentinel extraction"

run_case() {  # run_case <verdict> <DR_OUT>
  DR_VERDICT="$1"; DR_OUT="$2"
  DR_REASON="canned reason"; DR_PROOF="not_verified"; RIG="whatsapp_automation"
  BEAD_ID="ga-test"; BEAD_CITY="$TMP/city"; MERGE_SHA="deadbeef"; DR_PRE_SHA="aaaa1111"; DR_POST_SHA="bbbb2222"; DRY_RUN=0
  unset MERGE_PRE_MAIN_SHA 2>/dev/null || true     # genuinely unset on the DRY_RUN path — must not abort under nounset
  DAEMON_HOLD_VERDICT=""; DAEMON_HOLD_REASON=""; DAEMON_HOLD_DETAIL=""; DAEMON_SOFT_WARN=""; DAEMON_SOFT_WARN_LABEL=""
  : > "$BD_LOG"
  eval "$CASE_BLOCK"
  BD_CALLS="$(cat "$BD_LOG")"
}

run_case NEEDS_GUARDED_RESTART "$(mk_out NEEDS_GUARDED_RESTART "$LOCKED" "$LOCKED")"
[ -z "$DAEMON_HOLD_VERDICT" ] && ok "W1 a locked + cosmetic NEEDS_GUARDED_RESTART does NOT set the hold" || bad "W1 held ($DAEMON_HOLD_VERDICT) for a locked daemon the symbol split proves cosmetic — the bug"
[ "$DAEMON_SOFT_WARN_LABEL" = "delivery:daemon-stale-locked" ] && ok "W1 selects the delivery:daemon-stale-locked label (not 'could not check')" || bad "W1 label='$DAEMON_SOFT_WARN_LABEL'"
[ -n "$DAEMON_SOFT_WARN" ] && has "$DAEMON_SOFT_WARN" "$LOCKED" && ok "W1 the soft-warn text names the daemon" || bad "W1 soft-warn='$DAEMON_SOFT_WARN'"
has "$BD_CALLS" "comment ga-test" && has "$BD_CALLS" "$LOCKED" && has "$BD_CALLS" "notify_only_locked" \
  && ok "W1 the release is RECORDED on the bead: names the daemon and the reason (notify_only_locked)" \
  || bad "W1 no evidence comment naming the daemon + notify_only_locked" "$BD_CALLS"

run_case NEEDS_GUARDED_RESTART "$(mk_out NEEDS_GUARDED_RESTART "$LOCKED" "")"
[ "$DAEMON_HOLD_VERDICT" = "NEEDS_GUARDED_RESTART" ] && ok "W2 control: a locked daemon whose symbol IS reached (cosmetic empty) is still HELD" || bad "W2 hold='$DAEMON_HOLD_VERDICT'"
[ -z "$DAEMON_SOFT_WARN" ] && [ -z "$BD_CALLS" ] && ok "W2 ...with no soft-warn and no release comment" || bad "W2 soft='$DAEMON_SOFT_WARN' calls='$BD_CALLS'"

run_case NEEDS_GUARDED_RESTART "$(mk_out NEEDS_GUARDED_RESTART "$LOCKED" ABSENT)"
[ "$DAEMON_HOLD_VERDICT" = "NEEDS_GUARDED_RESTART" ] && ok "W3 control: a helper without the field is still HELD" || bad "W3 hold='$DAEMON_HOLD_VERDICT'"

run_case NEEDS_GUARDED_RESTART "$(mk_out NEEDS_GUARDED_RESTART "$LOCKED $PLAIN" "$LOCKED")"
[ "$DAEMON_HOLD_VERDICT" = "NEEDS_GUARDED_RESTART" ] && ok "W4 control: a mixed set is still HELD" || bad "W4 hold='$DAEMON_HOLD_VERDICT'"

run_case VERIFY_FAILED "$(mk_out VERIFY_FAILED "$LOCKED" "$LOCKED")"
[ "$DAEMON_HOLD_VERDICT" = "VERIFY_FAILED" ] && ok "W5 control: VERIFY_FAILED is still HELD even with a cosmetic line" || bad "W5 hold='$DAEMON_HOLD_VERDICT'"

run_case JOB_NOT_INSTALLED "$(mk_out JOB_NOT_INSTALLED "$LOCKED" "$LOCKED")"
[ "$DAEMON_HOLD_VERDICT" = "JOB_NOT_INSTALLED" ] && ok "W6 control: JOB_NOT_INSTALLED is still HELD" || bad "W6 hold='$DAEMON_HOLD_VERDICT'"

run_case OK "$(mk_out OK "" ABSENT)"
[ -z "$DAEMON_HOLD_VERDICT" ] && [ -n "$DAEMON_SOFT_WARN" ] && [ -z "$DAEMON_SOFT_WARN_LABEL" ] \
  && ok "W7 control: OK + proof=not_verified is still the ordinary soft-warn (label left to the default daemon-unverified)" \
  || bad "W7 hold='$DAEMON_HOLD_VERDICT' soft='$DAEMON_SOFT_WARN' label='$DAEMON_SOFT_WARN_LABEL'"

# ── C: the real extracted close snippet ─────────────────────────────────────
echo "── C. daemon-soft-warn-close (live extraction via sentinel) ──"
CLOSE_BLOCK="$(extract daemon-soft-warn-close)"
[ -n "$CLOSE_BLOCK" ] || { echo "FATAL: sentinel daemon-soft-warn-close not found in $DISPATCHER"; exit 1; }
ok "located the live soft-warn close snippet via sentinel extraction"

run_close() {  # run_close <soft-warn> <label>
  DAEMON_SOFT_WARN="$1"; DAEMON_SOFT_WARN_LABEL="$2"
  BEAD_ID="ga-test"; BEAD_CITY="$TMP/city"
  _CLOSE_REASON="Quality gate PASSED — merged."
  : > "$BD_LOG"
  eval "$CLOSE_BLOCK"
  BD_CALLS="$(cat "$BD_LOG")"
}

run_close "a locked daemon still runs the old code" "delivery:daemon-stale-locked"
has "$BD_CALLS" "label add ga-test delivery:daemon-stale-locked" && ok "C1 adds delivery:daemon-stale-locked" || bad "C1 label" "$BD_CALLS"
has "$BD_CALLS" "delivery:daemon-unverified" && bad "C1 also added delivery:daemon-unverified ('could not check' is not what happened)" || ok "C1 does NOT add delivery:daemon-unverified"
has "$_CLOSE_REASON" "ga-j3lh6p" && has "$_CLOSE_REASON" "delivery:daemon-stale-locked" && ok "C1 the close reason cites ga-j3lh6p and the label" || bad "C1 close reason" "$_CLOSE_REASON"
has "$_CLOSE_REASON" "not positively confirmed" && bad "C1 the close reason says liveness was 'not positively confirmed' (alarming for a proven-cosmetic case)" "$_CLOSE_REASON" || ok "C1 the close reason does not claim liveness was unconfirmed"

run_close "OK (x, proof=not_verified)" ""
has "$BD_CALLS" "label add ga-test delivery:daemon-unverified" && ok "C2 control: an empty label keeps the default delivery:daemon-unverified" || bad "C2 label" "$BD_CALLS"
has "$_CLOSE_REASON" "not positively confirmed" && ok "C2 control: the pre-existing close-reason wording is unchanged" || bad "C2 close reason" "$_CLOSE_REASON"

run_close "" ""
[ -z "$BD_CALLS" ] && [ "$_CLOSE_REASON" = "Quality gate PASSED — merged." ] && ok "C3 control: no soft-warn -> no label, close reason untouched" || bad "C3 calls='$BD_CALLS' reason='$_CLOSE_REASON'"

echo ""
echo "== result: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
