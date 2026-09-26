#!/usr/bin/env bash
# prod-tests/gascity/story-ga-mb57np.sh — prod test for ga-mb57np: hq's dolt_gc (and the
# ga-btnq6h staging release that unblocks it) was only evaluated once per 2h cycle against ONE
# `avail` sample on a disk whose "free" swings ±9 GB with swap — so the release never fired
# (62 consecutive skips, ~124h). The fix is a 5-minute poll that starts the existing job when
# the SAME gate is reachable.
#
# What shipped, and what this test proves about each part:
#   1. dolt-gc-release-trigger.sh  — the poll. Decides with the job's own functions, never deletes.
#   2. dolt-gc-maintenance.sh      — a triggered run does only the size-gated GC step; its skips
#                                    are not counted as 2h cycles; a single-instance lock stops
#                                    two runs overlapping (there was none).
#   3. com.gascity.dolt-gc-release-trigger.plist — the launchd job that runs (1) every 300s.
#
# Called by run.sh after deploy (STORY_ID=ga-mb57np). Exits 0 on pass. Asserts against the LIVE
# deployed tree ($CITY/scripts — gascity's scripts run in place) and live launchd state.
#
# NOT asserted here, on purpose: that the release/GC HAS happened. It waits for free space to
# actually peak and would fail every delivery made before then — the same reason ga-btnq6h's own
# test leaves it to a verification bead (acceptance: `staging-release: released …` + `dolt_gc OK —
# hq X -> Y` in .gc/logs/dolt-gc-maintenance.log, staging rebuilt by mol-dog-backup in ≤6h,
# nightly `OK`). Everything that CAN be known at delivery time is checked below — including that
# the poll is alive, which is the part that is silent when it is not.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
SCRIPTS="$CITY/scripts"
LABEL="com.gascity.dolt-gc-release-trigger"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$CITY/.gc/runtime/packs/maintenance/dolt-gc-release-trigger.state"
LOG="$CITY/.gc/logs/dolt-gc-maintenance.log"

log()  { echo "[prod-test:gascity ga-mb57np] $*"; }
fail() { echo "[prod-test:gascity ga-mb57np] FAIL: $*" >&2; exit 1; }

# macOS /bin/bash is 3.2 and is what launchd runs these with; Homebrew bash 5 accepts syntax 3.2
# rejects, so syntax-check with the interpreter that actually runs them.
BASH32=/bin/bash
[[ -x "$BASH32" ]] || fail "$BASH32 not found — cannot syntax-check under the interpreter the jobs run with"

TRG="$SCRIPTS/dolt-gc-release-trigger.sh"
GCM="$SCRIPTS/dolt-gc-maintenance.sh"

# ── 1. The deployed files exist and parse under bash 3.2 ─────────────────────────────
for f in "$TRG" "$GCM" "$SCRIPTS/dolt-gc-release-trigger.selftest.sh" "$SCRIPTS/dolt-gc-maintenance.selftest.sh"; do
  [[ -f "$f" ]] || fail "deployed file missing: $f (the merge did not reach the running tree)"
  "$BASH32" -n "$f" 2>/dev/null || fail "$f does not parse under $BASH32 (3.2) — the launchd job would die on start"
done
log "trigger, maintenance job and both selftests are deployed and parse under bash 3.2"

# ── 2. WIRED, not just present (a defined-but-never-called function is the classic dormant fix) ──
grep -q 'dolt-gc-maintenance.sh' "$TRG" \
  || fail "deployed trigger never references dolt-gc-maintenance.sh — it could not start the job"
grep -q 'GC_TRIGGERED_RUN=1 _trg_run_maintenance' "$TRG" \
  || fail "deployed trigger does not mark the run it starts as triggered (GC_TRIGGERED_RUN=1)"
grep -q '_gc_release_decision' "$TRG" \
  || fail "deployed trigger does not decide with _gc_release_decision — it would carry its own copy of the gate"
grep -q '_gc_required_parts "\$size_mb" "\$GC_MIN_FREE_PCT" "\$GC_MIN_FREE_ABS_MB"' "$GCM" \
  || fail "deployed dolt-gc-maintenance.sh does not compute the gate via _gc_required_parts (the trigger and the job could drift)"
grep -q '^_run_size_gc()' "$GCM" && grep -q '_run_size_gc$' "$GCM" \
  || fail "deployed dolt-gc-maintenance.sh lost the size-gated GC step function"
grep -Eq '_dgm_lock_acquire "\$GC_MAINT_LOCKDIR" "\$GC_MAINT_LOCK_RE"' "$GCM" \
  || fail "deployed dolt-gc-maintenance.sh does not take the single-instance lock at its entry point"
grep -q 'GC_TRIGGERED_RUN' "$GCM" \
  || fail "deployed dolt-gc-maintenance.sh does not know about triggered runs"
# the no-second-deletion-path property, checked on the deployed file itself
if grep -v '^[[:space:]]*#' "$TRG" | grep -Eq '(^|[^A-Za-z_])rm( |$)|rmdir|_gc_maybe_release_staging|_s3proof_'; then
  fail "deployed trigger references a deletion/release/S3-proof primitive — it must only decide and start the job"
fi
log "trigger wired to the job (decides with its functions, marks runs triggered, deletes nothing); job locks + has the GC-only step"

# ── 3. The regression suites pass against the LIVE tree ──────────────────────────────
run_suite() {  # run_suite <script-basename>
  local name="$1" out
  log "running $name against the live tree ..."
  out="$("$BASH32" "$SCRIPTS/$name" 2>&1)" || { echo "$out" | tail -40 >&2; fail "$name failed against the live tree"; }
  printf '%s\n' "$out" | grep -Eq 'RESULT: PASS=[0-9]+ FAIL=0( ===)?$' \
    || fail "$name did not report a clean FAIL=0 result: $(printf '%s\n' "$out" | tail -3)"
  log "  $(printf '%s\n' "$out" | grep -E 'RESULT: PASS=' | tail -1)"
}
run_suite dolt-gc-release-trigger.selftest.sh
run_suite dolt-gc-maintenance.selftest.sh

# ── 4. The poll is INSTALLED and LOADED (a present plist is not automation) ──────────
[[ -f "$PLIST" ]] || fail "$PLIST is not installed — copy packs/town-deltas/assets/dolt-gc-release-trigger.plist there and \`launchctl bootstrap gui/\$(id -u) $PLIST\`"
plutil -lint "$PLIST" >/dev/null 2>&1 || fail "$PLIST does not lint"
grep -q "$SCRIPTS/dolt-gc-release-trigger.sh" "$PLIST" \
  || fail "$PLIST does not run $SCRIPTS/dolt-gc-release-trigger.sh (installed copy points somewhere else)"
launchctl list 2>/dev/null | grep -q "$LABEL" \
  || fail "$LABEL is NOT registered with launchd — the poll never runs, so the release stays a 2h lottery"
log "$LABEL is installed, lints, points at the deployed script and is registered with launchd"

# ── 5. The poll is ALIVE: its state file was rewritten recently ──────────────────────
# Every poll rewrites the state (healthy or not), so a stale/missing state means launchd is not
# running it. RunAtLoad makes the first poll immediate; wait a little in case it is just loading.
state_age() {  # seconds since the last poll, empty when unknowable
  local p now; p="$(head -1 "$STATE" 2>/dev/null | tr ' ' '\n' | sed -n 's/^poll=\([0-9][0-9]*\)$/\1/p' | head -1)"
  [[ -n "$p" ]] || return 1
  now="$(date +%s)"; echo $(( now - p ))
}
age=""; waited=0
while :; do
  age="$(state_age)" && [[ "$age" -le 900 ]] && break
  [[ "$waited" -ge 120 ]] && break
  sleep 10; waited=$(( waited + 10 ))
done
if [[ -n "$age" && "$age" -le 900 ]]; then
  log "poll is alive: last poll ${age}s ago — $(head -1 "$STATE")"
else
  fail "the poll is not running: state file ${STATE} is $([[ -f "$STATE" ]] && echo "stale (last poll ${age:-unreadable}s ago; expected <= 900s)" || echo "absent") — check ~/gt/.gascity-gastown-hq/.gc/logs/dolt-gc-release-trigger-launchd.err"
fi

# ── informational, never failing ────────────────────────────────────────────────────
STREAK="$CITY/.gc/runtime/packs/maintenance/dolt-gc-skip-streak.state"
RELSTATE="$CITY/.gc/runtime/packs/maintenance/dolt-gc-staging-release.state"
[[ -s "$STREAK" ]] && log "info: dolt_gc skip streak state: $(head -1 "$STREAK")"
if [[ -s "$RELSTATE" ]]; then log "info: staging last released at epoch $(head -1 "$RELSTATE")"; else log "info: staging has not been released yet"; fi
grep -h 'trigger:' "$LOG" 2>/dev/null | tail -3 | while IFS= read -r l; do log "info: $l"; done
log "info: kill switch = GC_TRIGGER_ENABLED=0 in $CITY/.gc/config/dolt-maintenance.env (trigger only)"

log "PASS — 5-minute release trigger deployed, wired, tested against the live tree, loaded in launchd and alive; release/GC outcome is tracked by the verification bead"
exit 0
