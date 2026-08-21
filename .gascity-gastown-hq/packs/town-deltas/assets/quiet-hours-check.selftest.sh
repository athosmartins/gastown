#!/usr/bin/env bash
# quiet-hours-check.selftest.sh — Prove the ga-w8kbf fix: an ABSENT
# quiet-hours level file (the night-window mechanism deliberately disabled,
# e.g. after `launchctl bootout com.gascity.city-night-window`) must NOT be
# reported the same as a STALE or CORRUPT one (a writer that was running and
# broke — a real anomaly). Before this fix, _quiet_hours_unreadable()
# collapsed all three into "1", so all 5 dispatchers that source this file
# (pilot, quality-gate, auto-refino, refino-gate, context-check) logged
# "UNREADABLE (missing/stale/corrupt ...)" on every sweep, forever, for a
# state that is both permanent and correct — training the reader to ignore
# exactly the message that matters the day the signal genuinely breaks.
#
# Acceptance criteria under test (bead ga-w8kbf):
#   AC1. With the night window off (file absent), _quiet_hours_unreadable
#        returns "0" — dispatchers do not log a warning per sweep.
#   AC2. A genuinely stale or corrupt signal still returns "1" — the fix
#        must not blind the real anomaly case.
#   AC3. The two states (absent vs stale/corrupt) are distinguishable and
#        produce DIFFERENT outputs — this is the test the bug itself asks
#        for, not incidental coverage.
#   AC4. _quiet_hours_blocks and _quiet_hours_state are UNCHANGED by this
#        fix (regression guard) — only _quiet_hours_unreadable's absent-file
#        branch moved.
#   AC5. OVERRIDE seam still short-circuits unreadable to "0" regardless of
#        file state (pre-existing behavior, must survive this fix).
#   AC6. End-to-end: the exact `if [ "$(_quiet_hours_unreadable)" = "1" ];
#        then log ...; fi` shape every real call site uses produces NO log
#        line when the file is absent, and DOES produce one when stale.
#
# Runs entirely against the real quiet-hours-check.sh, sourced directly (it
# has no external dependencies — no bd/gc, no network), with
# QUIET_HOURS_LEVEL_FILE pointed at a disposable temp path per scenario. Safe
# on a live host — never touches the real ~/.gastown/run/ signal file.
#
# Exit 0 iff all assertions hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QHC="$SELF_DIR/quiet-hours-check.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$QHC" ]; then
  echo "FATAL: quiet-hours-check.sh not found at $QHC" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/quiet-hours-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# run_qhc <level-file-path> <fn-and-args...>
# Sources the real file fresh each call (functions read QUIET_HOURS_LEVEL_FILE
# at call time, not at source time, but a fresh source avoids any state
# leaking between scenarios) and invokes the given function in a subshell.
# Deliberately does NOT touch QUIET_HOURS_OVERRIDE here: this script never
# sets it globally, so it is naturally unset for every scenario UNLESS a
# caller prefixes the run_qhc invocation itself (`VAR=x run_qhc ...`), which
# only scopes the var to that one subshell — never leaks to later scenarios.
# (An earlier version of this helper force-unset it here, which silently
# discarded the AC5 override scenarios' own env-var prefix before it could
# ever reach the sourced functions — caught by AC5 failing even against the
# ORIGINAL pre-fix code, i.e. a red that had nothing to do with the real fix.)
run_qhc() {
  local level_file="$1"; shift
  # shellcheck disable=SC2034  # read by the dynamically-sourced $QHC below, not locally
  ( QUIET_HOURS_LEVEL_FILE="$level_file"
    # shellcheck disable=SC1090
    source "$QHC"
    "$@"
  )
}

FRESH_TS=$(date +%s)
STALE_TS=$(( FRESH_TS - 7200 ))  # 2h old, well past the 1800s default ceiling
ABSENT_PATH="$WORK/does-not-exist.level"

# ════════════════════════════════════════════════════════════════════════════
echo "Scenario 1 (AC1): file ABSENT -> unreadable=0 (the fix)"
OUT="$(run_qhc "$ABSENT_PATH" _quiet_hours_unreadable)"
[ "$OUT" = "0" ] && ok "AC1: absent file -> unreadable=0, not 1" || bad "AC1: expected 0, got '$OUT'"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 2 (AC2): file present, STALE timestamp -> unreadable=1 (must not blind this)"
STALE_FILE="$WORK/stale.level"
printf 'QUIET\n%s\n' "$STALE_TS" > "$STALE_FILE"
OUT="$(run_qhc "$STALE_FILE" _quiet_hours_unreadable)"
[ "$OUT" = "1" ] && ok "AC2: stale timestamp -> unreadable=1" || bad "AC2: expected 1, got '$OUT'"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 3 (AC2): file present, CORRUPT (non-numeric) timestamp -> unreadable=1"
CORRUPT_FILE="$WORK/corrupt.level"
printf 'QUIET\nnot-a-number\n' > "$CORRUPT_FILE"
OUT="$(run_qhc "$CORRUPT_FILE" _quiet_hours_unreadable)"
[ "$OUT" = "1" ] && ok "AC2: corrupt (non-numeric) timestamp -> unreadable=1" || bad "AC2: expected 1, got '$OUT'"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 4 (AC2): file present, CORRUPT (empty 2nd line) -> unreadable=1"
EMPTY_TS_FILE="$WORK/empty-ts.level"
printf 'QUIET\n\n' > "$EMPTY_TS_FILE"
OUT="$(run_qhc "$EMPTY_TS_FILE" _quiet_hours_unreadable)"
[ "$OUT" = "1" ] && ok "AC2: empty timestamp line -> unreadable=1" || bad "AC2: expected 1, got '$OUT'"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 5 (AC3): absent vs stale/corrupt are DISTINGUISHABLE (the bug's own ask)"
ABSENT_OUT="$(run_qhc "$ABSENT_PATH" _quiet_hours_unreadable)"
STALE_OUT="$(run_qhc "$STALE_FILE" _quiet_hours_unreadable)"
if [ "$ABSENT_OUT" != "$STALE_OUT" ]; then
  ok "AC3: absent ('$ABSENT_OUT') and stale ('$STALE_OUT') produce DIFFERENT outputs"
else
  bad "AC3: absent and stale collapsed to the SAME output ('$ABSENT_OUT') — this is the exact bug"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 6 (AC1 continued): fresh QUIET and fresh OPEN both stay unreadable=0 (unchanged)"
QUIET_FILE="$WORK/quiet-fresh.level"
printf 'QUIET\n%s\n' "$FRESH_TS" > "$QUIET_FILE"
OPEN_FILE="$WORK/open-fresh.level"
printf 'OPEN\n%s\n' "$FRESH_TS" > "$OPEN_FILE"
[ "$(run_qhc "$QUIET_FILE" _quiet_hours_unreadable)" = "0" ] \
  && ok "fresh QUIET -> unreadable=0" || bad "fresh QUIET should be unreadable=0"
[ "$(run_qhc "$OPEN_FILE" _quiet_hours_unreadable)" = "0" ] \
  && ok "fresh OPEN -> unreadable=0" || bad "fresh OPEN should be unreadable=0"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 7 (AC4 regression): _quiet_hours_blocks unchanged across all states"
[ "$(run_qhc "$ABSENT_PATH" _quiet_hours_blocks)" = "0" ] && ok "blocks: absent -> 0 (unchanged)" || bad "blocks: absent should stay 0"
[ "$(run_qhc "$STALE_FILE" _quiet_hours_blocks)" = "0" ] && ok "blocks: stale QUIET -> 0 (unchanged, stale fails open)" || bad "blocks: stale should stay 0"
[ "$(run_qhc "$CORRUPT_FILE" _quiet_hours_blocks)" = "0" ] && ok "blocks: corrupt -> 0 (unchanged)" || bad "blocks: corrupt should stay 0"
[ "$(run_qhc "$QUIET_FILE" _quiet_hours_blocks)" = "1" ] && ok "blocks: fresh QUIET -> 1 (unchanged)" || bad "blocks: fresh QUIET should stay 1"
[ "$(run_qhc "$OPEN_FILE" _quiet_hours_blocks)" = "0" ] && ok "blocks: fresh OPEN -> 0 (unchanged)" || bad "blocks: fresh OPEN should stay 0"

echo ""
echo "Scenario 7b (AC4 regression): _quiet_hours_state unchanged across all states"
[ "$(run_qhc "$ABSENT_PATH" _quiet_hours_state)" = "" ] && ok "state: absent -> '' (unchanged)" || bad "state: absent should stay empty"
[ "$(run_qhc "$QUIET_FILE" _quiet_hours_state)" = "QUIET" ] && ok "state: fresh QUIET -> 'QUIET' (unchanged)" || bad "state: fresh QUIET should stay QUIET"
[ "$(run_qhc "$STALE_FILE" _quiet_hours_state)" = "QUIET" ] && ok "state: stale QUIET -> 'QUIET' (unchanged — state is raw, staleness is a separate axis)" || bad "state: stale should still report raw QUIET"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 8 (AC5): OVERRIDE seam short-circuits unreadable to 0 regardless of file state"
OUT="$(QUIET_HOURS_OVERRIDE=QUIET run_qhc "$STALE_FILE" _quiet_hours_unreadable)"
[ "$OUT" = "0" ] && ok "AC5: OVERRIDE=QUIET makes even a stale file unreadable=0" || bad "AC5: expected 0 under override, got '$OUT'"
OUT="$(QUIET_HOURS_OVERRIDE=OPEN run_qhc "$CORRUPT_FILE" _quiet_hours_unreadable)"
[ "$OUT" = "0" ] && ok "AC5: OVERRIDE=OPEN makes even a corrupt file unreadable=0" || bad "AC5: expected 0 under override, got '$OUT'"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 9 (AC6): the exact call-site log-gate shape every real dispatcher uses"
call_site_would_log() {
  # Mirrors: elif [ "\$(_quiet_hours_unreadable)" = "1" ]; then log "..."; fi
  if [ "$(_quiet_hours_unreadable)" = "1" ]; then
    echo "WOULD_LOG"
  fi
}
ABSENT_LOG="$(run_qhc "$ABSENT_PATH" call_site_would_log)"
[ -z "$ABSENT_LOG" ] && ok "AC6: absent file -> real call-site shape logs NOTHING" || bad "AC6: absent file should not log, got '$ABSENT_LOG'"
STALE_LOG="$(run_qhc "$STALE_FILE" call_site_would_log)"
[ "$STALE_LOG" = "WOULD_LOG" ] && ok "AC6: stale file -> real call-site shape DOES log" || bad "AC6: stale file should log, got '$STALE_LOG'"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 10 (drift-guard): all 5 real dispatchers source this file and use the fixed wording"
DISPATCHERS="pilot-dispatcher.sh quality-gate-dispatcher.sh auto-refino-dispatcher.sh refino-gate-dispatcher.sh context-check-dispatcher.sh"
for d in $DISPATCHERS; do
  DF="$SELF_DIR/$d"
  if [ ! -f "$DF" ]; then
    bad "drift-guard: $d not found at $DF"
    continue
  fi
  if grep -q "quiet-hours-check.sh" "$DF"; then
    ok "drift-guard: $d sources quiet-hours-check.sh"
  else
    bad "drift-guard: $d does NOT source quiet-hours-check.sh — the 5-consumer list is stale again"
  fi
  # ga-w8kbf gate-fix-1: scoped to the "Quiet-hours signal" line SPECIFICALLY
  # — a bare "UNREADABLE (missing/stale/corrupt" match is exactly the
  # too-broad pattern that let the real fix's own `sed` silently reword an
  # UNRELATED line (pilot-dispatcher.sh's RAM-pressure monitor, ga-m2gqb,
  # never touched by this bead's actual code change) and falsely claim
  # "missing" was no longer a possible cause there too. Caught by gate
  # review, not by this test, the first time — this test had the identical
  # flaw and would have missed it. Never loosen this back to a bare suffix
  # match.
  if grep -q "Quiet-hours signal UNREADABLE (missing/stale/corrupt" "$DF"; then
    bad "drift-guard: $d still has the stale 'missing/stale/corrupt' wording on its QUIET-HOURS line (absent can no longer be the cause there)"
  else
    ok "drift-guard: $d has the corrected quiet-hours log wording (no 'missing' claim)"
  fi
done

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "SELFTEST PASS"
  exit 0
else
  echo "SELFTEST FAIL"
  exit 1
fi
