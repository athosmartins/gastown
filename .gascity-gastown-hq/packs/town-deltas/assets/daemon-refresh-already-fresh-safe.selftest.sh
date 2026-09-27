#!/usr/bin/env bash
# daemon-refresh-already-fresh-safe.selftest.sh — ga-95lo9b.
#
# THE DEFECT: already_fresh() (ga-j3j6s; refined ga-puq8z, gate-fix-2) was
# consulted ONLY inside the `is_sensitive || policy_says_sensitive` branch of
# daemon-refresh.sh's per-label loop. A SAFE daemon that is deploy_restart-
# listed but NOT sensitive (com.urblink.inbound-sweep: restart_policy.yaml
# explicitly keeps it out of sensitive_daemons — "já é 'seguro reiniciar a
# qualquer ponto'") went straight to guard_allows_restart() with no freshness
# short-circuit at all. When that daemon's restart_guard_scripts entry
# refuses for a reason UNRELATED to code staleness (inbound_sweep_restart_
# safe.py refuses whenever the daemon is mid-sweep, not "between chats" — a
# SCHEDULE-state guard, not a freshness guard, exactly as restart_policy.yaml's
# own comment on this daemon already documents), the label was flagged
# NEEDS_GUARDED_RESTART on nearly every sweep regardless of whether the
# process had already restarted onto fresh code via some other path (verified
# live 2026-09-27: a guarded restart verified fresh at 06:08 was still
# re-flagged at 06:55-07:05, because already_fresh() was never reached for
# this label).
#
# THE FIX: hoist the already_fresh() check to run once for every
# AFFECTED+running label, before the is_sensitive/policy_says_sensitive
# branch — so a SAFE daemon gets the identical floor-epoch proof a SENSITIVE
# one always had, and never reaches guard_allows_restart() at all once
# already proven fresh. Can only ever ADD true-fresh detections (same safety
# argument point 7 already established for the SENSITIVE-only version) —
# never mask a real stale daemon: a label that fails the check falls through
# to the SENSITIVE/SAFE branches completely unchanged.
#
# T1 is the regression case: it FAILS against the pre-fix loop (already_fresh
# never called for a non-sensitive label, so a refusing guard alone flags
# GUARDED) and PASSES once already_fresh() is hoisted above both branches.
# T2-T7 are controls proving every pre-existing branch (SAFE guard-refused,
# SAFE restarted, SENSITIVE already-fresh, SENSITIVE no-drain, SENSITIVE
# drain+guard-refused, not-running) is byte-for-byte unchanged.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SELF_DIR/daemon-refresh.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

echo "== daemon-refresh-already-fresh-safe.selftest (ga-95lo9b) =="

extract() { sed -n "/# SELFTEST-EXTRACT $1: BEGIN/,/# SELFTEST-EXTRACT $1: END/p" "$HELPER"; }
LOOP_BLOCK="$(extract daemon-refresh-label-loop)"
[ -n "$LOOP_BLOCK" ] || { echo "FATAL: sentinel daemon-refresh-label-loop not found in $HELPER"; exit 1; }
ok "located the live per-label loop via sentinel extraction"

LABEL="com.urblink.inbound-sweep"

# run_loop <pid|ABSENT> <fresh:0|1> <afr_tier> <sensitive:0|1> <policy_sensitive:0|1> \
#          <guard_rc> <verify_rc> <drain_cmd|ABSENT> <dry_run>
run_loop() {
  local pid="$1" fresh_rc="$2" tier="$3" sens="$4" polsens="$5" guard_rc="$6" verify_rc="$7" drain="$8" dry="$9"
  AFFECTED="$LABEL"
  AFFECTED_NOT_RUNNING="" ALREADY_FRESH="" ALREADY_FRESH_PROOF="" GUARDED="" RESTARTED="" FRESH_FAIL="" WOULD_RESTART=""
  DEPLOY_EPOCH=1790499000 COMMIT_EPOCH=1790498000
  DRY_RUN="$dry"
  LAUNCHCTL_BIN="true"
  GUARD_CALLS=0
  ALREADY_FRESH_CALLS=0
  daemon_pid() { [ "$pid" = "ABSENT" ] && return 0; echo "$pid"; }
  already_fresh() { ALREADY_FRESH_CALLS=$((ALREADY_FRESH_CALLS+1)); AFR_TIER="$tier"; return "$fresh_rc"; }
  is_sensitive() { return "$sens"; }
  policy_says_sensitive() { return "$polsens"; }
  guard_allows_restart() { GUARD_CALLS=$((GUARD_CALLS+1)); return "$guard_rc"; }
  verify_fresh() { return "$verify_rc"; }
  classify_guarded() { :; }
  log() { :; }
  if [ "$drain" != "ABSENT" ]; then
    # shellcheck disable=SC2140
    eval "DRAIN_CMD_${LABEL//[^A-Za-z0-9_]/_}=\"$drain\""
  else
    unset "DRAIN_CMD_${LABEL//[^A-Za-z0-9_]/_}" 2>/dev/null || true
  fi
  eval "$LOOP_BLOCK"
}

# ── T1: the regression case ──────────────────────────────────────────────
echo "── T1. SAFE (not sensitive) + already-fresh + a refusing guard ──"
run_loop 12345 0 verified 1 1 1 0 ABSENT 1
if has " $ALREADY_FRESH " " $LABEL " && ! has " $GUARDED " " $LABEL "; then
  ok "T1 label classified ALREADY_FRESH, never GUARDED"
else
  bad "T1 already_fresh='$ALREADY_FRESH' guarded='$GUARDED' — the bug: a SAFE daemon already proven fresh still reaches the (refusing) guard"
fi
[ "$GUARD_CALLS" -eq 0 ] && ok "T1 guard_allows_restart was NEVER called — the already-fresh short-circuit fired before it" \
  || bad "T1 guard_allows_restart called $GUARD_CALLS time(s) — freshness proof did not short-circuit the guard consultation"
[ "$ALREADY_FRESH_CALLS" -eq 1 ] && ok "T1 already_fresh consulted exactly once" || bad "T1 already_fresh called $ALREADY_FRESH_CALLS time(s)"

# ── T2: control — SAFE, not fresh, guard refuses (pre-existing GUARDED path) ─
echo "── T2. control: SAFE + NOT fresh + refusing guard -> still GUARDED ──"
run_loop 12345 1 not_verified 1 1 1 0 ABSENT 1
if has " $GUARDED " " $LABEL " && ! has " $ALREADY_FRESH " " $LABEL "; then
  ok "T2 control: guarded exactly as before"
else
  bad "T2 already_fresh='$ALREADY_FRESH' guarded='$GUARDED'"
fi
[ "$GUARD_CALLS" -eq 1 ] && ok "T2 control: guard consulted once (freshness check correctly failed first)" || bad "T2 guard called $GUARD_CALLS time(s)"

# ── T3: control — SAFE, not fresh, guard allows -> kickstart + verify ────────
echo "── T3. control: SAFE + NOT fresh + guard allows -> restarts ──"
run_loop 12345 1 not_verified 1 1 0 0 ABSENT 0
if has " $RESTARTED " " $LABEL " && ! has " $FRESH_FAIL " " $LABEL " && ! has " $GUARDED " " $LABEL "; then
  ok "T3 control: kickstart path unchanged (restarted, verified fresh)"
else
  bad "T3 restarted='$RESTARTED' freshfail='$FRESH_FAIL' guarded='$GUARDED'"
fi

# ── T4: control — SENSITIVE + already-fresh (pre-existing ga-j3j6s path) ────
echo "── T4. control: SENSITIVE + already-fresh -> ALREADY_FRESH, verified tier ──"
run_loop 12345 0 verified 0 1 1 0 ABSENT 1
if has " $ALREADY_FRESH " " $LABEL " && [ -z "$ALREADY_FRESH_PROOF" ]; then
  ok "T4 control: sensitive already-fresh (verified tier) unchanged"
else
  bad "T4 already_fresh='$ALREADY_FRESH' proof='$ALREADY_FRESH_PROOF'"
fi
[ "$GUARD_CALLS" -eq 0 ] && ok "T4 control: guard never consulted for an already-fresh sensitive daemon" || bad "T4 guard called $GUARD_CALLS time(s)"

# ── T5: control — SENSITIVE + NOT fresh + no drain -> GUARDED ───────────────
echo "── T5. control: SENSITIVE + NOT fresh + no drain configured -> GUARDED ──"
run_loop 12345 1 not_verified 0 1 1 0 ABSENT 1
has " $GUARDED " " $LABEL " && ! has " $ALREADY_FRESH " " $LABEL " \
  && ok "T5 control: sensitive/no-drain/not-fresh still GUARDED" \
  || bad "T5 already_fresh='$ALREADY_FRESH' guarded='$GUARDED'"

# ── T6: control — SENSITIVE + NOT fresh + drain configured + guard refuses ──
echo "── T6. control: SENSITIVE + NOT fresh + drain configured + guard refuses -> GUARDED ──"
run_loop 12345 1 not_verified 0 1 1 0 "true" 1
has " $GUARDED " " $LABEL " && [ "$GUARD_CALLS" -eq 1 ] \
  && ok "T6 control: sensitive drain path still respects a refusing guard" \
  || bad "T6 guarded='$GUARDED' guard_calls=$GUARD_CALLS"

# ── T7: control — no live PID -> AFFECTED_NOT_RUNNING, already_fresh never called ─
echo "── T7. control: daemon not running -> AFFECTED_NOT_RUNNING, no freshness check ──"
run_loop ABSENT 0 verified 1 1 1 0 ABSENT 1
has " $AFFECTED_NOT_RUNNING " " $LABEL " && [ "$ALREADY_FRESH_CALLS" -eq 0 ] && [ "$GUARD_CALLS" -eq 0 ] \
  && ok "T7 control: not-running short-circuits before any freshness/guard check" \
  || bad "T7 affected_not_running='$AFFECTED_NOT_RUNNING' already_fresh_calls=$ALREADY_FRESH_CALLS guard_calls=$GUARD_CALLS"

echo ""
echo "== result: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
