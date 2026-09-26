#!/bin/bash
# dolt-gc-release-trigger.selftest.sh — tests for dolt-gc-release-trigger.sh (ga-mb57np).
#
# The defect this guards: the staging release + dolt_gc were only evaluated once per 2h cycle,
# against ONE `avail` sample on a disk whose "free" swings ±9 GB with swap — a lottery. The
# trigger polls that number every few minutes and starts the (unchanged) maintenance job when
# the SAME gate would pass. So the tests pin (1) the timeline property — a peak between two 2h
# samples is caught — and (2) that the trigger can never be a second way to delete or a way to
# hammer S3: it decides with the existing pure functions, backs off, and is single-instance.
#
# Hermetic: sources the trigger as a LIBRARY (DOLT_GC_TRIGGER_LIB=1); `du`/`df` readers, the
# busy check, the maintenance launch and the clock are stubs; state lives in a throwaway dir.
# Real Dolt / S3 / launchd are NEVER touched and NOTHING is deleted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIGGER="$HERE/dolt-gc-release-trigger.sh"
MAINT="$HERE/dolt-gc-maintenance.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/dolt-gc-trigger-selftest.XXXXXX")"
[ -n "$T" ] && [ -d "$T" ] || { echo "FATAL: mktemp failed"; exit 2; }
export DOLT_GC_TRIGGER_LIB=1
export DOLT_MAINT_CONF="$T/noconf.env"                 # nonexistent → no real toggle is read
export DOLT_GC_MAINT_LOG="$T/maint.log"
export GC_SKIP_STREAK_STATE="$T/streak.state"           # the real one lives under $CITY/.gc/runtime
export GC_TRIGGER_STATE="$T/trigger.state"
export GC_TRIGGER_LOCKDIR="$T/trigger.lock.d"
export GC_MAINT_LOCKDIR="$T/maint.lock.d"
export GC_RELEASE_STATE="$T/release.state"
export GC_RELEASE_BACKUP_LOCKDIR="$T/nightly.lock.d"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-gc-release-trigger.selftest.sh ==="

if [ ! -f "$TRIGGER" ]; then
  bad "the trigger script does not exist: $TRIGGER"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi
# shellcheck disable=SC1090
. "$TRIGGER"

# ── _gc_trigger_decision: pure. Args: streak avail size staging pct floor min_streak slack
#    release_enabled(1|0) cooldown_ok(1|0). World = the measured 2026-09-26 numbers:
#    hq 8247MB, local staging 9601MB, gate = max(200% size, size+3072) = 16494MB, slack 2048.
#    Release becomes eligible at avail >= 16494 + 2048 - 9601 = 8941MB. ──────────────────────
dec() { _gc_trigger_decision "$@"; }
S=53; SZ=8247; ST=9601; PCT=200; FL=3072; MIN=6; SL=2048
[ "$(dec $S 7263 $SZ $ST $PCT $FL $MIN $SL 1 1)" = "WAIT would-not-unblock-gc" ] && ok "decision: today's real sample (avail 7263) → WAIT would-not-unblock-gc — no run is started for nothing" || bad "decision today got: '$(dec $S 7263 $SZ $ST $PCT $FL $MIN $SL 1 1)'"
[ "$(dec $S 8941 $SZ $ST $PCT $FL $MIN $SL 1 1)" = "KICK release" ] && ok "decision: avail 8941 (= required+slack-staging) → KICK release (boundary, exact to the MB)" || bad "decision boundary got: '$(dec $S 8941 $SZ $ST $PCT $FL $MIN $SL 1 1)'"
[ "$(dec $S 8940 $SZ $ST $PCT $FL $MIN $SL 1 1)" = "WAIT would-not-unblock-gc" ] && ok "decision: avail 8940 (1MB short) → WAIT" || bad "decision boundary-1 got: '$(dec $S 8940 $SZ $ST $PCT $FL $MIN $SL 1 1)'"
[ "$(dec $S 16494 $SZ $ST $PCT $FL $MIN $SL 1 1)" = "KICK direct" ] && ok "decision: the gate passes with no release (avail 16494) → KICK direct (the GC itself can run)" || bad "decision direct got: '$(dec $S 16494 $SZ $ST $PCT $FL $MIN $SL 1 1)'"
[ "$(dec $S 16493 $SZ $ST $PCT $FL $MIN $SL 1 1)" = "KICK release" ] && ok "decision: 1MB under the direct gate but release clears it → KICK release" || bad "decision direct-1 got: '$(dec $S 16493 $SZ $ST $PCT $FL $MIN $SL 1 1)'"
[ "$(dec 5 20000 $SZ $ST $PCT $FL $MIN $SL 1 1)" = "WAIT streak-too-short" ] && ok "decision: not chronic (streak 5 < 6) → WAIT even with ample space (the 2h cycle owns non-chronic states)" || bad "decision short streak got: '$(dec 5 20000 $SZ $ST $PCT $FL $MIN $SL 1 1)'"
[ "$(dec 6 20000 $SZ $ST $PCT $FL $MIN $SL 1 1)" = "KICK direct" ] && ok "decision: streak exactly at the minimum is chronic (boundary)" || bad "decision streak==min got: '$(dec 6 20000 $SZ $ST $PCT $FL $MIN $SL 1 1)'"
[ "$(dec $S 12000 $SZ $ST $PCT $FL $MIN $SL 0 1)" = "WAIT release-disabled" ] && ok "decision: kill switch off + gate not met alone → WAIT release-disabled (no run started to be refused)" || bad "decision release-off got: '$(dec $S 12000 $SZ $ST $PCT $FL $MIN $SL 0 1)'"
[ "$(dec $S 16494 $SZ $ST $PCT $FL $MIN $SL 0 1)" = "KICK direct" ] && ok "decision: kill switch off does not stop a direct GC (no release involved)" || bad "decision direct+release-off got: '$(dec $S 16494 $SZ $ST $PCT $FL $MIN $SL 0 1)'"
[ "$(dec $S 12000 $SZ $ST $PCT $FL $MIN $SL 1 0)" = "WAIT cooldown" ] && ok "decision: release cooldown not elapsed → WAIT cooldown" || bad "decision cooldown got: '$(dec $S 12000 $SZ $ST $PCT $FL $MIN $SL 1 0)'"
[ "$(dec $S 12000 $SZ 0 $PCT $FL $MIN $SL 1 1)" = "WAIT no-staging" ] && ok "decision: no local staging to free (already released) and gate not met → WAIT no-staging" || bad "decision no-staging got: '$(dec $S 12000 $SZ 0 $PCT $FL $MIN $SL 1 1)'"
[ "$(dec $S 16494 $SZ 0 $PCT $FL $MIN $SL 1 1)" = "KICK direct" ] && ok "decision: staging already gone but the gate passes on its own → KICK direct (retry after a short re-gate)" || bad "decision no-staging+direct got: '$(dec $S 16494 $SZ 0 $PCT $FL $MIN $SL 1 1)'"
[ "$(dec $S 12000 $SZ "" $PCT $FL $MIN $SL 1 1)" = "WAIT unmeasurable-input" ] && ok "decision: staging size unreadable (blank) → WAIT unmeasurable-input, never a guess" || bad "decision blank staging got: '$(dec $S 12000 $SZ "" $PCT $FL $MIN $SL 1 1)'"
_all=1
_args=($S 12000 $SZ $ST $PCT $FL $MIN $SL 1 1)
for _pos in 1 2 3 5 6 7 8; do   # every numeric input except staging (4th, covered above; blank staging can still be a direct KICK)
  for _val in "" "abc" "-1" "1.5" "12MB"; do
    _a=("${_args[@]}"); _a[$((_pos-1))]="$_val"
    [ "$(_gc_trigger_decision "${_a[@]}")" = "WAIT unmeasurable-input" ] || { _all=0; echo "    (arg $_pos='$_val' was not refused as unmeasurable: '$(_gc_trigger_decision "${_a[@]}")')"; }
  done
done
[ "$_all" = "1" ] && ok "decision: every other numeric input blank/non-numeric/negative/decimal → WAIT unmeasurable-input (a failed read never looks like 'plenty of room')" || bad "decision: an unmeasurable input was not refused"
unset _all _args _pos _val _a
# Consistency by construction: the trigger must agree with the functions the maintenance job
# itself uses, over a grid — no second copy of the arithmetic that could drift.
_grid_ok=1
for _av in 0 3000 7263 8940 8941 9000 12486 16493 16494 20000; do
  for _stg in 0 5000 9601; do
    _want="WAIT"
    _req="$(_gc_required_parts $SZ $PCT $FL | awk '{print $3}')"
    if _gc_headroom_ok "$_av" $SZ $PCT && _gc_floor_ok "$_av" $SZ $FL; then _want="KICK direct"
    elif [ "$(_gc_release_decision $S "$_av" "$_stg" "$_req" $MIN $SL)" = "RELEASE" ]; then _want="KICK release"; fi
    _got="$(dec $S "$_av" $SZ "$_stg" $PCT $FL $MIN $SL 1 1)"
    case "$_got" in WAIT*) _got="WAIT" ;; esac
    [ "$_got" = "$_want" ] || { _grid_ok=0; echo "    (avail=$_av staging=$_stg: trigger says '$_got', maintenance functions say '$_want')"; }
  done
done
[ "$_grid_ok" = "1" ] && ok "decision: over an avail×staging grid the trigger agrees exactly with _gc_headroom_ok/_gc_floor_ok/_gc_release_decision" || bad "decision: trigger disagrees with the maintenance gate on the grid"
unset _grid_ok _av _stg _want _req _got

# ── THE regression: sampled every 2h the peak is missed; polled every 5 min it is caught. ──
# Series shape from the live log (avail swings 3-12 GB with swap); one 12.5 GB peak at minute
# 205, i.e. between the 2h samples at minutes 120 and 240. At HEAD there is no poll at all.
_avail_at() {   # minute → avail MB (deterministic stand-in for the swap-driven swing)
  case "$1" in
    200|205|210) echo 12486 ;;
    *) echo $(( 3600 + ( $1 * 37 ) % 3400 )) ;;   # 3.6-7.0 GB otherwise
  esac
}
_cyc=0; _poll=0
for _m in 0 120 240 360; do [ "$(dec $S "$(_avail_at $_m)" $SZ $ST $PCT $FL $MIN $SL 1 1)" = "KICK release" ] && _cyc=$((_cyc+1)); done
for _m in $(seq 0 5 360); do case "$(dec $S "$(_avail_at $_m)" $SZ $ST $PCT $FL $MIN $SL 1 1)" in KICK*) _poll=$((_poll+1)) ;; esac; done
[ "$_cyc" -eq 0 ] && ok "timeline: the four 2h-cycle samples (min 0/120/240/360) all miss the peak — the lottery the bead measured" || bad "timeline: 2h sampling unexpectedly caught the peak ($_cyc)"
[ "$_poll" -ge 1 ] && ok "timeline: the 5-min poll sees the peak ($_poll eligible sample(s)) and would start the job" || bad "timeline: the poll did not catch the peak"
unset _cyc _poll _m; unset -f _avail_at

# ── state helpers ─────────────────────────────────────────────────────────────────────────
rm -f "$GC_TRIGGER_STATE"
_trg_state_write "$GC_TRIGGER_STATE" 1000 "WAIT x" 2 1300 && ok "state: written" || bad "state: write failed"
[ "$(_trg_state_get "$GC_TRIGGER_STATE" attempts)" = "2" ] && [ "$(_trg_state_get "$GC_TRIGGER_STATE" next_allowed)" = "1300" ] && [ "$(_trg_state_get "$GC_TRIGGER_STATE" poll)" = "1000" ] && ok "state: round-trips poll/attempts/next_allowed" || bad "state round-trip: '$(cat "$GC_TRIGGER_STATE")'"
printf 'garbage\n' > "$GC_TRIGGER_STATE"
[ "$(_trg_state_get "$GC_TRIGGER_STATE" attempts)" = "0" ] && [ "$(_trg_state_get "$GC_TRIGGER_STATE" next_allowed)" = "0" ] && ok "state: garbled file reads as attempts=0 next_allowed=0 (and is rewritten by the next poll)" || bad "state garbled read wrong"
rm -f "$GC_TRIGGER_STATE"
[ "$(_trg_state_get "$GC_TRIGGER_STATE" attempts)" = "0" ] && ok "state: absent file reads as attempts=0" || bad "state absent read wrong"
mkdir -p "$T/statedir"
_trg_state_write "$T/statedir" 1000 "x" 0 0 2>/dev/null && bad "state: writing onto a directory must fail" || ok "state: an unwritable state path fails the write (callers fail closed on it)"
rmdir "$T/statedir"

# ── _trg_backoff_s: 5m → 10m → 20m … capped ───────────────────────────────────────────────
GC_TRIGGER_BACKOFF_BASE_S=300; GC_TRIGGER_BACKOFF_MAX_S=7200
[ "$(_trg_backoff_s 1)" = "300" ] && [ "$(_trg_backoff_s 2)" = "600" ] && [ "$(_trg_backoff_s 3)" = "1200" ] && [ "$(_trg_backoff_s 5)" = "4800" ] && ok "backoff: 1→300s, 2→600s, 3→1200s, 5→4800s (doubles)" || bad "backoff series: $(_trg_backoff_s 1) $(_trg_backoff_s 2) $(_trg_backoff_s 3) $(_trg_backoff_s 5)"
[ "$(_trg_backoff_s 6)" = "7200" ] && [ "$(_trg_backoff_s 40)" = "7200" ] && [ "$(_trg_backoff_s 400)" = "7200" ] && ok "backoff: capped at 7200s (and no overflow for a huge attempt count)" || bad "backoff cap: $(_trg_backoff_s 6) $(_trg_backoff_s 40) $(_trg_backoff_s 400)"
[ "$(_trg_backoff_s abc)" = "7200" ] && [ "$(_trg_backoff_s "")" = "7200" ] && ok "backoff: a non-numeric attempt count backs off to the cap (never to 0)" || bad "backoff garbage: '$(_trg_backoff_s abc)' '$(_trg_backoff_s "")'"

# ═══ trigger_main end to end ═════════════════════════════════════════════════════════════
# Real: state file, streak file, own lock, log, clock arithmetic, decision order.
# Stubs: disk/dir readers, the busy check, the maintenance launch.
KICKS=0; KICK_ENV=""; KICK_MODE="fail"      # fail = leave the streak alone; ok = clear it (the GC was attempted)
AVAIL=10000; SIZE_MB=8247; STAGING_MB=9601; BUSY=""
_avail_mb() { printf '%s' "$AVAIL"; }
_trg_dir_mb() { case "$1" in */.beads/dolt/hq) printf '%s' "$SIZE_MB" ;; */.dolt-backup/hq) printf '%s' "$STAGING_MB" ;; *) printf '' ;; esac; }
_gc_release_busy() { if [ -n "$BUSY" ]; then echo "$BUSY"; return 0; fi; return 1; }
_trg_run_maintenance() { KICKS=$((KICKS+1)); KICK_ENV="${GC_TRIGGERED_RUN:-}"; [ "$KICK_MODE" = "ok" ] && printf '0 0\n' > "$GC_SKIP_STREAK_STATE"; return 0; }
NOW=2000000000
reset_main() {
  rm -rf "$T/city"; mkdir -p "$T/city/.dolt-backup/hq" "$T/city/.beads/dolt/hq" "$T/rt"
  printf '5:__DOLT__:lock:root:gcgen\n' > "$T/city/.dolt-backup/hq/manifest"
  BACKUP_STAGING="$T/city/.dolt-backup"; DB="hq"; DOLTDIR="$T/city/.beads/dolt/hq"
  rm -f "$GC_TRIGGER_STATE" "$GC_RELEASE_STATE" "$DOLT_GC_MAINT_LOG"; rm -rf "$GC_TRIGGER_LOCKDIR" "$GC_MAINT_LOCKDIR" "$GC_RELEASE_BACKUP_LOCKDIR"
  printf '53 1\n' > "$GC_SKIP_STREAK_STATE"
  GC_TRIGGER_ENABLED=1; GC_RELEASE_STAGING_ENABLED=1; GC_RELEASE_MIN_STREAK=6; GC_RELEASE_SLACK_MB=2048; GC_RELEASE_COOLDOWN_H=168
  GC_MIN_FREE_PCT=""; PRUNE_ENABLED=0; GC_MIN_FREE_ABS_MB=3072; THRESHOLD_G=1
  GC_TRIGGER_BACKOFF_BASE_S=300; GC_TRIGGER_BACKOFF_MAX_S=7200
  KICKS=0; KICK_ENV=""; KICK_MODE="fail"; AVAIL=10000; SIZE_MB=8247; STAGING_MB=9601; BUSY=""; GC_NOW_EPOCH=$NOW
}
poll() { trigger_main >/dev/null 2>&1; }
sget() { _trg_state_get "$GC_TRIGGER_STATE" "$1"; }
sdec() { sed -n 's/.*decision=\(.*\) attempts=.*/\1/p' "$GC_TRIGGER_STATE" 2>/dev/null; }

reset_main; AVAIL=7263
poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT would-not-unblock-gc" ] && ok "poll: today's real sample → no run started, decision recorded in the state file (the heartbeat)" || bad "poll ineligible: kicks=$KICKS state='$(cat "$GC_TRIGGER_STATE" 2>/dev/null)'"
[ "$(sget poll)" = "$NOW" ] && ok "poll: the state file carries this poll's epoch (liveness evidence for the operator/prod-test)" || bad "poll epoch: '$(sget poll)'"

reset_main; AVAIL=12486
poll
[ "$KICKS" -eq 1 ] && [ "$KICK_ENV" = "1" ] && ok "poll: peak sample (12486) → the maintenance job started once, with GC_TRIGGERED_RUN=1" || bad "poll eligible: kicks=$KICKS env='$KICK_ENV'"
[ "$(sget attempts)" = "1" ] && [ "$(sget next_allowed)" = "$((NOW+300))" ] && ok "poll: a run that did not clear the streak counts as attempt 1 and arms a 300s backoff" || bad "poll attempt bookkeeping: '$(cat "$GC_TRIGGER_STATE")'"

# backoff: the next polls inside the window do NOT start another run; after it, they do (doubling)
GC_NOW_EPOCH=$((NOW+60)); poll
[ "$KICKS" -eq 1 ] && [ "$(sdec)" = "WAIT backoff" ] && ok "backoff: still eligible 60s later → no second run, decision WAIT backoff" || bad "backoff inside: kicks=$KICKS dec='$(sdec)'"
GC_NOW_EPOCH=$((NOW+300)); poll
[ "$KICKS" -eq 2 ] && [ "$(sget attempts)" = "2" ] && [ "$(sget next_allowed)" = "$((NOW+300+600))" ] && ok "backoff: at the boundary the next attempt starts, and the following backoff doubles to 600s" || bad "backoff boundary: kicks=$KICKS state='$(cat "$GC_TRIGGER_STATE")'"
GC_NOW_EPOCH=$((NOW+300+599)); poll
[ "$KICKS" -eq 2 ] && ok "backoff: 1s before the doubled window ends → still no run" || bad "backoff 1s early started a run (kicks=$KICKS)"

# success clears the bookkeeping
reset_main; AVAIL=12486; KICK_MODE="ok"
poll
[ "$KICKS" -eq 1 ] && [ "$(sget attempts)" = "0" ] && [ "$(sget next_allowed)" = "0" ] && ok "success: the run attempted the GC (streak cleared) → attempts back to 0, no backoff" || bad "success bookkeeping: kicks=$KICKS state='$(cat "$GC_TRIGGER_STATE")'"

# a run that is REFUSED is a failed attempt, not silence: state shows it
reset_main; AVAIL=12486
poll; GC_NOW_EPOCH=$((NOW+300)); poll; GC_NOW_EPOCH=$((NOW+300+600)); poll
[ "$KICKS" -eq 3 ] && [ "$(sget attempts)" = "3" ] && ok "backoff: three refused attempts in a row are all recorded (attempts=3)" || bad "three failures: kicks=$KICKS attempts=$(sget attempts)"

# not chronic → nothing, and it is CHEAP: neither disk reader is consulted
reset_main; printf '2 0\n' > "$GC_SKIP_STREAK_STATE"; AVAIL=20000
_READS=0; _avail_mb() { _READS=$((_READS+1)); printf '%s' "$AVAIL"; }
poll
[ "$KICKS" -eq 0 ] && [ "$_READS" -eq 0 ] && [ "$(sdec)" = "WAIT streak-too-short" ] && ok "poll: healthy state (streak below the minimum) → exits after reading one small file, no disk read, no run" || bad "poll non-chronic: kicks=$KICKS reads=$_READS dec='$(sdec)'"
_avail_mb() { printf '%s' "$AVAIL"; }
reset_main; rm -f "$GC_SKIP_STREAK_STATE"; AVAIL=20000; poll
[ "$KICKS" -eq 0 ] && ok "poll: no streak state at all (unreadable = not chronic) → no run" || bad "poll no-streak-state started a run"
reset_main; printf 'junk\n' > "$GC_SKIP_STREAK_STATE"; AVAIL=20000; poll
[ "$KICKS" -eq 0 ] && ok "poll: garbled streak state → no run" || bad "poll junk-streak started a run"

# unmeasurable inputs never start a run
reset_main; AVAIL=""; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT unmeasurable-input" ] && ok "poll: avail unreadable → no run, recorded as unmeasurable-input" || bad "poll blank avail: kicks=$KICKS dec='$(sdec)'"
reset_main; SIZE_MB=""; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT unmeasurable-input" ] && ok "poll: hq size unreadable → no run" || bad "poll blank size: kicks=$KICKS dec='$(sdec)'"
reset_main; STAGING_MB=""; AVAIL=12000; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT unmeasurable-input" ] && ok "poll: staging size unreadable on a real staging dir → no run" || bad "poll blank staging: kicks=$KICKS dec='$(sdec)'"

# hq below the maintenance job's own size threshold → the job would skip; do not start it
reset_main; SIZE_MB=500; AVAIL=20000; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT hq-below-threshold" ] && ok "poll: hq under THRESHOLD_G → no run (the job would skip anyway)" || bad "poll small hq: kicks=$KICKS dec='$(sdec)'"

# release path vetoes that must NOT count as an attempt
reset_main; AVAIL=12000; BUSY="backup-writer-running"; poll
[ "$KICKS" -eq 0 ] && [ "$(sget attempts)" = "0" ] && [[ "$(sdec)" == "WAIT staging-busy"* ]] && ok "poll: staging busy (a backup writer) → no run, and it does NOT escalate the backoff" || bad "poll busy: kicks=$KICKS attempts=$(sget attempts) dec='$(sdec)'"
reset_main; AVAIL=12000; printf '%s\n' $((NOW-3600)) > "$GC_RELEASE_STATE"; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT cooldown" ] && ok "poll: inside the release cooldown → no run" || bad "poll cooldown: kicks=$KICKS dec='$(sdec)'"
reset_main; AVAIL=12000; rm -rf "$T/city/.dolt-backup/hq"; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT no-staging" ] && ok "poll: no local staging directory → no release run" || bad "poll no staging dir: kicks=$KICKS dec='$(sdec)'"
reset_main; AVAIL=20000; rm -rf "$T/city/.dolt-backup/hq"; poll
[ "$KICKS" -eq 1 ] && ok "poll: no staging but the gate passes on its own → the GC run starts" || bad "poll direct w/o staging: kicks=$KICKS"
reset_main; AVAIL=20000; BUSY="backup-writer-running"; poll
[ "$KICKS" -eq 1 ] && ok "poll: a busy staging does not stop a direct GC (nothing is released on that path)" || bad "poll direct while busy: kicks=$KICKS"
reset_main; AVAIL=12000; GC_RELEASE_STAGING_ENABLED=0; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT release-disabled" ] && ok "poll: GC_RELEASE_STAGING_ENABLED=0 → no release run" || bad "poll kill switch: kicks=$KICKS dec='$(sdec)'"

# the trigger's own kill switch
reset_main; AVAIL=20000; GC_TRIGGER_ENABLED=0; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "DISABLED" ] && ok "kill switch: GC_TRIGGER_ENABLED=0 → no run, state says DISABLED" || bad "trigger kill switch: kicks=$KICKS dec='$(sdec)'"

# single instance: a live maintenance run, and a live sibling poll, both stand it down
reset_main; AVAIL=20000
mkdir -p "$GC_MAINT_LOCKDIR"; printf '%s\n' "$$" > "$GC_MAINT_LOCKDIR/pid"; GC_MAINT_LOCK_RE="selftest"
poll
[ "$KICKS" -eq 0 ] && [ "$(sget attempts)" = "0" ] && [ "$(sdec)" = "WAIT maintenance-running" ] && ok "lock: a live maintenance run → no second run, not counted as an attempt" || bad "maint lock: kicks=$KICKS attempts=$(sget attempts) dec='$(sdec)'"
GC_MAINT_LOCK_RE='dolt-gc-maintenance'
reset_main; AVAIL=20000
mkdir -p "$GC_TRIGGER_LOCKDIR"; printf '%s\n' "$$" > "$GC_TRIGGER_LOCKDIR/pid"; GC_TRIGGER_LOCK_RE="selftest"
poll
[ "$KICKS" -eq 0 ] && [ ! -e "$GC_TRIGGER_STATE" ] && ok "lock: a live sibling poll holds the trigger lock → this poll does nothing (state untouched)" || bad "trigger lock: kicks=$KICKS state_exists=$([ -e "$GC_TRIGGER_STATE" ] && echo y || echo n)"
GC_TRIGGER_LOCK_RE='dolt-gc-release-trigger'
reset_main; AVAIL=20000; poll
[ ! -e "$GC_TRIGGER_LOCKDIR" ] && ok "lock: the trigger lock is released when the poll ends" || bad "trigger lock leaked after a poll"

# fail closed when the attempt cannot be recorded: an unwritable state means no run
reset_main; AVAIL=20000; mkdir -p "$GC_TRIGGER_STATE"
poll
[ "$KICKS" -eq 0 ] && ok "fail-closed: the state cannot be written (so a backoff could not be recorded) → no run" || bad "unwritable state still started a run (kicks=$KICKS)"
rmdir "$GC_TRIGGER_STATE" 2>/dev/null

# A state file that EXISTS but cannot be read is "don't know", not "no history": the backoff it
# held may be lost, so this poll stays inert, says so (log + decision), and rewrites a clean
# state; the NEXT poll proceeds normally. (Absent = first run = no history, and does run.)
reset_main; AVAIL=20000; printf 'garbage\n' > "$GC_TRIGGER_STATE"; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT state-unreadable" ] && [ "$(sget poll)" = "$NOW" ] && ok "state: a garbled state file → this poll stays inert, records WAIT state-unreadable and rewrites a clean state" || bad "garbled state: kicks=$KICKS state='$(cat "$GC_TRIGGER_STATE")'"
grep -q 'state file .* unreadable' "$DOLT_GC_MAINT_LOG" && ok "state: the unreadable state is logged (visible, not silent)" || bad "state: unreadable state not logged"
poll
[ "$KICKS" -eq 1 ] && ok "state: the poll after the reset proceeds normally (the trigger is not wedged)" || bad "after reset: kicks=$KICKS"
reset_main; AVAIL=20000; : > "$GC_TRIGGER_STATE"; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT state-unreadable" ] && ok "state: an EMPTY state file (torn write) is unreadable too → inert once" || bad "empty state: kicks=$KICKS dec='$(sdec)'"
reset_main; AVAIL=20000; poll
[ "$KICKS" -eq 1 ] && ok "state: an ABSENT state file is a first run (no history) → proceeds" || bad "absent state: kicks=$KICKS"

# a lock that cannot be created leaves the trigger inert but says so
reset_main; AVAIL=20000; printf 'x' > "$T/afile"; GC_TRIGGER_LOCKDIR="$T/afile/trigger.lock.d"; poll
[ "$KICKS" -eq 0 ] && grep -q 'cannot create the trigger lock' "$DOLT_GC_MAINT_LOG" && ok "lock: an uncreatable trigger lock → no run, and it is logged (inert but not silent)" || bad "uncreatable lock: kicks=$KICKS"
GC_TRIGGER_LOCKDIR="$T/trigger.lock.d"

# ═══ gate round 1 (ga-mb57np): unknown / partial input must never take the run path ═════════
# Class: "a case that only vetoes the known-bad". Everywhere the poll consumes a value that could
# be missing or half-written, only the EXACT known-good shapes may proceed; anything else is a
# third state ("don't know") and stays inert, visibly.

# (1) The decision. Only the two exact KICK strings start a run — a blank/garbled decision (what a
#     failed $(...) yields: fork ENOMEM/EAGAIN, a jetsam-killed subshell) is NOT a KICK.
_saved_dec="$(declare -f _gc_trigger_decision)"
_gc_trigger_decision() { printf '%s' "$FAKE_DECISION"; }
for FAKE_DECISION in "" "garbage" "KICK" "kick direct" "KICK direct please" "RELEASE" "KICK  release"; do
  reset_main; AVAIL=20000; poll
  [ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT unknown-decision" ] && ok "decision allow-list: '${FAKE_DECISION}' is not a KICK → no run, state says WAIT unknown-decision" || bad "decision '${FAKE_DECISION}' started or mis-recorded: kicks=$KICKS dec='$(sdec)'"
done
for FAKE_DECISION in "KICK direct" "KICK release"; do
  reset_main; AVAIL=20000; poll
  [ "$KICKS" -eq 1 ] && ok "decision allow-list: the exact string '${FAKE_DECISION}' still starts the job" || bad "exact '${FAKE_DECISION}' did not start the job (kicks=$KICKS)"
done
reset_main; AVAIL=20000; FAKE_DECISION="garbage"; poll
grep -q "unrecognized decision 'garbage'" "$DOLT_GC_MAINT_LOG" && ok "decision allow-list: the unrecognized text is logged (visible, not silent)" || bad "unrecognized decision not logged"
[ "$(sget attempts)" = "0" ] && ok "decision allow-list: an undecided poll is not an attempt (no backoff escalation)" || bad "unknown decision counted as an attempt ($(sget attempts))"
eval "$_saved_dec"; unset _saved_dec FAKE_DECISION

# (1b) The same shape one level down: the release verdict. Anything that is not REFUSE <reason> or
#      RELEASE is unknown, not a WAIT with a blank reason.
( _gc_release_decision() { printf ''; }
  [ "$(dec $S 12000 $SZ $ST $PCT $FL $MIN $SL 1 1)" = "WAIT unknown-release-decision" ] ) && ok "decision: a blank release verdict → WAIT unknown-release-decision (never a blank reason, never a KICK)" || bad "blank release verdict got: '$( _gc_release_decision() { printf ''; }; dec $S 12000 $SZ $ST $PCT $FL $MIN $SL 1 1)'"
( _gc_release_decision() { printf 'garbage'; }
  [ "$(dec $S 12000 $SZ $ST $PCT $FL $MIN $SL 1 1)" = "WAIT unknown-release-decision" ] ) && ok "decision: a garbled release verdict → WAIT unknown-release-decision" || bad "garbled release verdict got: '$( _gc_release_decision() { printf 'garbage'; }; dec $S 12000 $SZ $ST $PCT $FL $MIN $SL 1 1)'"

# (2) The state record. A line that has poll= but lost the rest (attempts/next_allowed) used to read
#     as readable with attempts=0 next_allowed=0 → a first run, the backoff lost. Only a COMPLETE,
#     newline-terminated record is readable; every cut/partial shape is unreadable → inert once.
_part_ok=1; _n=0
# \c in printf %b stops the output there — no trailing newline — which is how a cut write looks.
_partials=(
  "poll=$NOW decision=KICK release (runn\\c"
  "poll=$NOW\\n"
  "poll=$NOW decision=WAIT x attempts=6\\n"
  "poll=$NOW decision=WAIT x attempts=6 next_allowed=\\n"
  "poll=$NOW decision=WAIT x attempts=6 next_allowed=70\\c"
  "poll=$NOW decision=WAIT x attempts=abc next_allowed=1\\n"
  "poll=$NOW attempts=6 next_allowed=99999999999\\n"
  "decision=WAIT x attempts=6 next_allowed=99999999999\\n"
)
for _line in "${_partials[@]}"; do
  _n=$((_n+1))
  reset_main; AVAIL=20000
  printf '%b' "$_line" > "$GC_TRIGGER_STATE"
  poll
  if [ "$KICKS" -ne 0 ] || [ "$(sdec)" != "WAIT state-unreadable" ]; then _part_ok=0; echo "    (partial record #$_n started a run or was mis-read: kicks=$KICKS dec='$(sdec)' line='$_line')"; fi
done
[ "$_part_ok" = "1" ] && ok "state: every partial/torn record shape (cut after poll=, missing attempts/next_allowed, cut mid-digits with no newline, non-numeric, no poll=) → unreadable: no run, WAIT state-unreadable" || bad "state: a partial record was treated as readable (see lines above)"
unset _part_ok _n _line _partials
# and a COMPLETE record — including the one a crash mid-run leaves behind — still reads, and its
# backoff is honoured (the reset above must not make the trigger forget a real backoff).
reset_main; AVAIL=20000; printf 'poll=%s decision=KICK release (running) attempts=6 next_allowed=%s\n' "$((NOW-10))" "$((NOW+7000))" > "$GC_TRIGGER_STATE"; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT backoff" ] && [ "$(sget attempts)" = "6" ] && ok "state: a complete record left by a crash mid-run is readable and its backoff is still in force" || bad "complete crash record: kicks=$KICKS dec='$(sdec)' attempts=$(sget attempts)"
reset_main; AVAIL=20000; printf 'poll=%s decision=WAIT backoff attempts=2 next_allowed=%s\n' "$((NOW-10))" "$((NOW-1))" > "$GC_TRIGGER_STATE"; poll
[ "$KICKS" -eq 1 ] && ok "state: a complete record whose backoff has elapsed lets the run proceed" || bad "complete elapsed record blocked the run (kicks=$KICKS)"

# (3) The clock. A blank/non-numeric `now` made [ "$now" -lt "$next_allowed" ] an ERROR (false) and
#     the poll went on to run. No clock → no decision, no state write (a stale heartbeat is the signal).
_saved_now="$(declare -f _gc_now_epoch)"
for _bad_now in "" "abc" "12x"; do
  reset_main; AVAIL=20000
  eval "_gc_now_epoch() { printf '%s' '$_bad_now'; }"; unset GC_NOW_EPOCH
  poll
  [ "$KICKS" -eq 0 ] && [ ! -e "$GC_TRIGGER_STATE" ] && grep -q 'clock' "$DOLT_GC_MAINT_LOG" && ok "clock: unreadable epoch '${_bad_now}' → no run, no state written, logged" || bad "clock '${_bad_now}': kicks=$KICKS state_exists=$([ -e "$GC_TRIGGER_STATE" ] && echo y || echo n)"
done
# the clock read AFTER the run: blank → the outcome record must still be a readable record with a
# real backoff (falls back to the poll's own start epoch), not "poll= …" (unreadable, backoff lost).
reset_main; AVAIL=20000
# (the clock is read inside $(...), a subshell — a counter there would not persist; KICKS is set by
#  the run stub in the parent shell, so "has the run happened yet" is visible to the stub)
_gc_now_epoch() { if [ "$KICKS" -eq 0 ]; then printf '%s' "$NOW"; else printf ''; fi; }
poll
_trg_state_readable "$GC_TRIGGER_STATE" && [ "$(sget attempts)" = "1" ] && [ "$(sget next_allowed)" -ge "$((NOW+300))" ] && ok "clock: blank epoch after the run → the outcome is still a readable record with the backoff armed" || bad "post-run clock: '$(cat "$GC_TRIGGER_STATE")'"
eval "$_saved_now"; GC_NOW_EPOCH=$NOW; unset _saved_now _bad_now

# (4) The size threshold. A garbled THRESHOLD_G skipped the "the job would skip anyway" pre-check
#     and went on to run; it must be inert like every other unmeasurable input.
reset_main; AVAIL=20000; THRESHOLD_G="abc"; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT unmeasurable-input" ] && ok "threshold: a non-numeric THRESHOLD_G → no run, recorded as unmeasurable-input" || bad "garbled threshold: kicks=$KICKS dec='$(sdec)'"
reset_main; AVAIL=20000; THRESHOLD_G=""; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT unmeasurable-input" ] && ok "threshold: an empty THRESHOLD_G → no run" || bad "empty threshold: kicks=$KICKS dec='$(sdec)'"

# (5) The fail-closed claim of the header: a state that is READABLE but cannot be written (so the
#     attempt cannot be recorded, so no backoff) must not start a run. (The earlier test uses a
#     directory, which is caught one step earlier as "unreadable" — it never reached this branch.)
if [ "$(id -u)" != "0" ]; then
  reset_main; AVAIL=20000
  printf 'poll=%s decision=WAIT backoff attempts=0 next_allowed=0\n' "$((NOW-10))" > "$GC_TRIGGER_STATE"; chmod 444 "$GC_TRIGGER_STATE"; poll
  [ "$KICKS" -eq 0 ] && grep -q 'cannot write' "$DOLT_GC_MAINT_LOG" && ok "fail-closed: a readable but read-only state → the attempt cannot be recorded → no run, logged" || bad "read-only state: kicks=$KICKS"
  chmod 644 "$GC_TRIGGER_STATE"
fi

# ── the trigger is NOT a second way to delete, and does not export lib mode to its child ──
_code="$(grep -v '^[[:space:]]*#' "$TRIGGER")"
printf '%s\n' "$_code" | grep -Eq '(^|[^A-Za-z_])rm( |$)|rmdir|unlink|_gc_maybe_release_staging|_s3proof_' && bad "static: the trigger references a deletion/release/proof primitive — it must only DECIDE and start the job" || ok "static: no rm/rmdir/unlink, no release or S3-proof call in the trigger — deletion stays in the maintenance job"
printf '%s\n' "$_code" | grep -Eq 'export +DOLT_GC_MAINT_LIB' && bad "static: the trigger exports DOLT_GC_MAINT_LIB — the job it starts would load as a library and do nothing" || ok "static: DOLT_GC_MAINT_LIB is not exported (the started job runs main, not as a library)"
printf '%s\n' "$_code" | grep -Eq 'GC_TRIGGERED_RUN=1' && ok "static: the job is started with GC_TRIGGERED_RUN=1" || bad "static: GC_TRIGGERED_RUN=1 not passed to the started job"
/bin/bash -n "$TRIGGER" 2>/dev/null && ok "static: parses under /bin/bash (3.2) — the interpreter launchd runs it with" || bad "static: does not parse under /bin/bash 3.2"
unset _code

unset -f _avail_mb _trg_dir_mb _gc_release_busy _trg_run_maintenance reset_main poll sget sdec dec
case "$T" in "${TMPDIR:-/tmp}"/dolt-gc-trigger-selftest.*) rm -rf "$T" ;; esac

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
