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
# The real run body, captured BEFORE the end-to-end section stubs it: until gate round 2 no test
# ran it (the env hand-off to the job it starts was only ever seen through the stub).
_REAL_RUN_MAINT="$(declare -f _trg_run_maintenance)"

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
KICKS=0; KICK_ENV=""; KICK_MODE="fail"; KICK_RC=0   # fail = leave the streak alone; ok = clear it (the GC was attempted); else = mangle_streak <mode>
AVAIL=10000; SIZE_MB=8247; STAGING_MB=9601; BUSY=""
# The readers COUNT into files: the poll calls them inside $(...), a subshell, so a shell-variable
# counter never reaches the parent — which made the old "no disk read" assertion vacuous (it passed
# with the reads moved ahead of the chronic check; found by the gate round 2 reviewer's mutants).
_avail_mb() { echo x >> "$T/reads.avail"; printf '%s' "$AVAIL"; }
_trg_dir_mb() { echo x >> "$T/reads.du"; case "$1" in */.beads/dolt/hq) printf '%s' "$SIZE_MB" ;; */.dolt-backup/hq) printf '%s' "$STAGING_MB" ;; *) printf '' ;; esac; }
_gc_release_busy() { echo x >> "$T/reads.busy"; if [ -n "$BUSY" ]; then echo "$BUSY"; return 0; fi; return 1; }
nreads() { if [ -f "$T/reads.$1" ]; then wc -l < "$T/reads.$1" | tr -d '[:space:]'; else echo 0; fi; }
# mangle_streak <mode> — put the job's skip-streak file into a shape the job never writes (or remove it).
mangle_streak() {
  local f="$GC_SKIP_STREAK_STATE"
  chmod 644 "$f" 2>/dev/null; rm -f "$f" 2>/dev/null; rmdir "$f" 2>/dev/null
  case "$1" in
    remove)     ;;
    empty)      : > "$f" ;;
    garble)     printf 'zz\n' > "$f" ;;
    partial)    printf '5' > "$f" ;;               # cut mid-write: no newline
    nocount)    printf '\n' > "$f" ;;
    noflag)     printf '53\n' > "$f" ;;
    badflag)    printf '53 2\n' > "$f" ;;
    zeroone)    printf '0 1\n' > "$f" ;;
    leadzero)   printf '053 1\n' > "$f" ;;
    twolines)   printf '53 1\n0 0\n' > "$f" ;;
    trailing)   printf '53 1 x\n' > "$f" ;;
    dir)        mkdir "$f" ;;
    unreadable) printf '53 1\n' > "$f"; chmod 000 "$f" ;;   # transient EACCES-style read failure
  esac
}
_stub_run() {
  KICKS=$((KICKS+1)); KICK_ENV="${GC_TRIGGERED_RUN:-}"
  case "$KICK_MODE" in
    fail) ;;
    ok)   printf '0 0\n' > "$GC_SKIP_STREAK_STATE" ;;
    *)    mangle_streak "$KICK_MODE" ;;
  esac
  return "${KICK_RC:-0}"
}
_trg_run_maintenance() { _stub_run; }   # (a function called from the stub sees the caller's GC_TRIGGERED_RUN=1 prefix)
NOW=2000001600     # % 3600 == 0: the first poll of an hour (the hourly-throttled WARNs log here)
reset_main() {
  rm -rf "$T/city"; mkdir -p "$T/city/.dolt-backup/hq" "$T/city/.beads/dolt/hq" "$T/rt"
  printf '5:__DOLT__:lock:root:gcgen\n' > "$T/city/.dolt-backup/hq/manifest"
  BACKUP_STAGING="$T/city/.dolt-backup"; DB="hq"; DOLTDIR="$T/city/.beads/dolt/hq"
  rm -f "$GC_TRIGGER_STATE" "$GC_RELEASE_STATE" "$DOLT_GC_MAINT_LOG" "$T"/reads.*; rm -rf "$GC_TRIGGER_LOCKDIR" "$GC_MAINT_LOCKDIR" "$GC_RELEASE_BACKUP_LOCKDIR"
  mangle_streak remove; printf '53 1\n' > "$GC_SKIP_STREAK_STATE"
  GC_TRIGGER_ENABLED=1; GC_RELEASE_STAGING_ENABLED=1; GC_RELEASE_MIN_STREAK=6; GC_RELEASE_SLACK_MB=2048; GC_RELEASE_COOLDOWN_H=168
  GC_MIN_FREE_PCT=""; PRUNE_ENABLED=0; GC_MIN_FREE_ABS_MB=3072; THRESHOLD_G=1
  GC_TRIGGER_BACKOFF_BASE_S=300; GC_TRIGGER_BACKOFF_MAX_S=7200
  KICKS=0; KICK_ENV=""; KICK_MODE="fail"; KICK_RC=0; AVAIL=10000; SIZE_MB=8247; STAGING_MB=9601; BUSY=""; GC_NOW_EPOCH=$NOW
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

# not chronic → nothing, and it is CHEAP: none of the three readers (df, du, the busy ps) is consulted.
# (Counted through files — see the reader stubs: a shell-variable counter dies in the $(...) subshell.)
reset_main; printf '2 0\n' > "$GC_SKIP_STREAK_STATE"; AVAIL=20000
poll
[ "$KICKS" -eq 0 ] && [ "$(nreads avail)" -eq 0 ] && [ "$(nreads du)" -eq 0 ] && [ "$(nreads busy)" -eq 0 ] && [ "$(sdec)" = "WAIT streak-too-short" ] && ok "poll: healthy state (streak below the minimum) → exits after reading one small file: no df, no du, no ps, no run" || bad "poll non-chronic: kicks=$KICKS avail=$(nreads avail) du=$(nreads du) busy=$(nreads busy) dec='$(sdec)'"
# the counter must be able to see a read at all, or the assertion above proves nothing
reset_main; AVAIL=12486; poll
[ "$(nreads avail)" -ge 1 ] && [ "$(nreads du)" -ge 2 ] && ok "poll: (control) in a chronic state the readers ARE counted (df=$(nreads avail), du=$(nreads du)) — the cheap-poll assertion is not vacuous" || bad "control: readers not counted (avail=$(nreads avail) du=$(nreads du))"
reset_main; mangle_streak remove; AVAIL=20000; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT streak-too-short" ] && ok "poll: NO streak file (the job never skipped) → no streak, not chronic → no run" || bad "poll no-streak-state: kicks=$KICKS dec='$(sdec)'"
reset_main; mangle_streak garble; AVAIL=20000; poll
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

# ═══ gate round 2 (ga-mb57np): the run's OUTCOME and the streak read are third-state too ══════
# The reviewer's repro: the job REFUSED (its streak file still said "53 1") but the trigger's read of
# that file after the run failed → the read collapsed to "0" = "the job cleared it": it logged
# "dolt_gc ran", reset the backoff to attempts=0/next_allowed=0, and the very next poll started a
# SECOND run. The job's own reader is fail-SAFE for alerts (garbled → "0 0"), which is right for a
# counter that only drives a notify and wrong here. Class: a value that could not be read must never
# take the branch that means "it worked" — three states (cleared / still standing / cannot tell),
# and "cannot tell" is treated like "still standing".

# (1) The strict reader itself — every shape, including the ones the job never writes.
_sr() { printf '%b' "$1" > "$T/sr.state"; _trg_streak_read "$T/sr.state"; }
_sr_ok=1
_chk() { [ "$(_sr "$1")" = "$2" ] || { _sr_ok=0; echo "    (streak file '$1' read as '$(_sr "$1")', want '$2')"; }; }
_chk '0 0\n'      "cleared"
_chk '53 1\n'     "standing 53"
_chk '1 0\n'      "standing 1"
_chk '62 0\n'     "standing 62"
_chk ''           "unreadable"          # empty
_chk '\n'         "unreadable"          # a bare newline
_chk 'zz\n'       "unreadable"
_chk '5\c'        "unreadable"          # cut mid-write: no newline
_chk '53 1\c'     "unreadable"          # a complete-looking record with no newline is a torn write
_chk '53\n'       "unreadable"          # alerted flag missing
_chk '53 2\n'     "unreadable"          # the flag is 0|1
_chk '0 1\n'      "unreadable"          # cleared is EXACTLY "0 0" (what _clear_skip_streak writes)
_chk '00 0\n'     "unreadable"
_chk '053 1\n'    "unreadable"          # no leading zeros: the job never writes them
_chk ' 53 1\n'    "unreadable"
_chk '53  1\n'    "unreadable"
_chk '53 1 x\n'   "unreadable"
_chk '5 3 1\n'    "unreadable"
_chk '53 1\n0 0\n' "unreadable"         # exactly one record
_chk '-1 0\n'     "unreadable"
_chk '53 1\n\c'   "standing 53"         # (control) the same record, newline present
[ "$_sr_ok" = "1" ] && ok "streak reader: exactly '0 0\\n' is cleared; '<n> <0|1>\\n' (n>=1, no leading zero) is standing; every other shape (empty, cut, torn, extra field, 0 1, two lines, ...) is unreadable" || bad "streak reader misclassified a shape (see lines above)"
unset -f _chk; unset _sr_ok
rm -f "$T/sr.state"; [ "$(_trg_streak_read "$T/sr.state")" = "absent" ] && ok "streak reader: no file → absent (the job never skipped — no streak, not unreadable)" || bad "streak reader absent: '$(_trg_streak_read "$T/sr.state")'"
mkdir -p "$T/sr.dir"; [ "$(_trg_streak_read "$T/sr.dir")" = "unreadable" ] && ok "streak reader: a directory where the file should be → unreadable" || bad "streak reader dir: '$(_trg_streak_read "$T/sr.dir")'"; rmdir "$T/sr.dir"
if [ "$(id -u)" != "0" ]; then
  printf '53 1\n' > "$T/sr.state"; chmod 000 "$T/sr.state"
  [ "$(_trg_streak_read "$T/sr.state")" = "unreadable" ] && ok "streak reader: a file that exists but cannot be opened → unreadable (never 'cleared', never 0)" || bad "streak reader chmod 000: '$(_trg_streak_read "$T/sr.state")'"
  chmod 644 "$T/sr.state"
fi
rm -f "$T/sr.state"; unset -f _sr

# (2) THE regression: the outcome after a run. Every shape the file can be left in that is not exactly
#     "0 0" counts as NOT cleared: the attempt is counted, the backoff armed, the log says it cannot tell.
_out_ok=1
for _mode in remove empty garble partial nocount noflag badflag zeroone leadzero twolines trailing dir; do
  reset_main; AVAIL=12486; KICK_MODE="$_mode"; poll
  if [ "$KICKS" -eq 1 ] && [ "$(sget attempts)" = "1" ] && [ "$(sget next_allowed)" = "$((NOW+300))" ] \
     && ! grep -q 'skip streak is cleared' "$DOLT_GC_MAINT_LOG" && grep -q 'cannot tell whether the job cleared' "$DOLT_GC_MAINT_LOG"; then :
  else _out_ok=0; echo "    (streak left as '$_mode' after the run: kicks=$KICKS state='$(cat "$GC_TRIGGER_STATE" 2>/dev/null)' log='$(grep 'trigger:' "$DOLT_GC_MAINT_LOG" | tail -1)')"; fi
done
[ "$_out_ok" = "1" ] && ok "outcome: a streak file left absent/empty/garbled/torn/'0 1'/two-line/directory after the run → NOT 'cleared': attempt counted, 300s backoff armed, the log says it cannot tell" || bad "outcome: an unreadable streak after the run was taken as 'cleared' (see lines above)"
unset _out_ok _mode
if [ "$(id -u)" != "0" ]; then
  # The reviewer's own repro: the read fails TRANSIENTLY right after the run (the file still says
  # "53 1"). Old code: attempts=0, next_allowed=0, and the next poll started a second run.
  reset_main; AVAIL=12486; KICK_MODE="unreadable"; poll
  chmod 644 "$GC_SKIP_STREAK_STATE"
  [ "$KICKS" -eq 1 ] && [ "$(sget attempts)" = "1" ] && [ "$(sget next_allowed)" = "$((NOW+300))" ] && ok "outcome: the after-run read FAILED (file still '53 1') → treated as not cleared: attempts=1, backoff armed" || bad "transient after-read: kicks=$KICKS state='$(cat "$GC_TRIGGER_STATE" 2>/dev/null)'"
  KICK_MODE="fail"; GC_NOW_EPOCH=$((NOW+60)); poll
  [ "$KICKS" -eq 1 ] && [ "$(sdec)" = "WAIT backoff" ] && ok "outcome: ...and the very next poll does NOT start a second run (the reviewer's repro: backoff was erased, a 2nd run started)" || bad "transient after-read: next poll kicks=$KICKS dec='$(sdec)' (a second run started = backoff lost)"
fi
# a well-formed STANDING streak keeps its own (unchanged) message; "0 0" is still the only cleared
reset_main; AVAIL=12486; KICK_MODE="fail"; poll
grep -q 'WITHOUT clearing the skip streak (streak=53)' "$DOLT_GC_MAINT_LOG" && ok "outcome: a readable standing streak is reported as such (streak=53)" || bad "standing streak message missing"
reset_main; AVAIL=12486; KICK_MODE="ok"; poll
grep -q 'skip streak is cleared' "$DOLT_GC_MAINT_LOG" && [ "$(sget attempts)" = "0" ] && [ "$(sget next_allowed)" = "0" ] && ok "outcome: exactly '0 0' is still 'cleared' → attempts back to 0 (success path intact)" || bad "cleared path broke: '$(cat "$GC_TRIGGER_STATE" 2>/dev/null)'"
# the child's exit status is no longer discarded
reset_main; AVAIL=12486; KICK_MODE="fail"; KICK_RC=127; poll
grep -q 'exited rc=127' "$DOLT_GC_MAINT_LOG" && [ "$(sget attempts)" = "1" ] && ok "outcome: a job that could not start (rc=127) is logged as such, not as 'the job refused (see the lines above)'" || bad "rc not logged: $(grep 'trigger:' "$DOLT_GC_MAINT_LOG" | tail -1)"
reset_main; AVAIL=12486; KICK_MODE="ok"; KICK_RC=137; poll
grep -q 'exited rc=137' "$DOLT_GC_MAINT_LOG" && ok "outcome: a nonzero exit is logged even when the streak reads cleared" || bad "rc 137 not logged"

# (3) The SAME read at decision time. Inert direction (a garbled file used to read as 0 →
#     "streak-too-short"), but the state file then said something FALSE. Now: unreadable = its own
#     decision, not an attempt, and the backoff it does not touch stays.
_dt_ok=1
for _mode in empty garble partial nocount noflag badflag zeroone leadzero twolines trailing dir; do
  reset_main; AVAIL=20000; mangle_streak "$_mode"
  printf 'poll=%s decision=WAIT backoff attempts=3 next_allowed=%s\n' "$((NOW-10))" "$((NOW+1000))" > "$GC_TRIGGER_STATE"
  poll
  if [ "$KICKS" -ne 0 ] || [ "$(sdec)" != "WAIT streak-unreadable" ] || [ "$(sget attempts)" != "3" ] || [ "$(sget next_allowed)" != "$((NOW+1000))" ]; then _dt_ok=0; echo "    (streak '$_mode' at decision time: kicks=$KICKS state='$(cat "$GC_TRIGGER_STATE" 2>/dev/null)')"; fi
done
[ "$_dt_ok" = "1" ] && ok "decision-time: an unreadable streak file → no run, state says WAIT streak-unreadable (not the false 'streak-too-short'), the recorded backoff is untouched" || bad "decision-time: an unreadable streak was mislabelled or acted on (see lines above)"
unset _dt_ok _mode
reset_main; AVAIL=20000; mangle_streak zeroone; poll
grep -q "skip-streak file .* is not a complete" "$DOLT_GC_MAINT_LOG" && ok "decision-time: the unreadable streak is logged (visible, not silent)" || bad "decision-time: unreadable streak not logged"
reset_main; AVAIL=20000; printf '0 0\n' > "$GC_SKIP_STREAK_STATE"; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT streak-too-short" ] && ok "decision-time: '0 0' (cleared) is a KNOWN not-chronic state → WAIT streak-too-short" || bad "decision-time '0 0': kicks=$KICKS dec='$(sdec)'"

# (4) A backoff belongs to an EPISODE. Once the streak is KNOWN to be below the minimum (the 2h job's
#     own GC cleared it), the episode is over: the next one starts at attempt 1, not near the cap.
reset_main; AVAIL=12486; printf '2 0\n' > "$GC_SKIP_STREAK_STATE"
printf 'poll=%s decision=KICK release (running) attempts=4 next_allowed=%s\n' "$((NOW-10))" "$((NOW+7000))" > "$GC_TRIGGER_STATE"
poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT streak-too-short" ] && [ "$(sget attempts)" = "0" ] && [ "$(sget next_allowed)" = "0" ] && ok "episode: streak known below the minimum → the previous episode's backoff (attempts=4, +7000s) is dropped" || bad "episode reset: kicks=$KICKS state='$(cat "$GC_TRIGGER_STATE" 2>/dev/null)'"
printf '53 1\n' > "$GC_SKIP_STREAK_STATE"; GC_NOW_EPOCH=$((NOW+10)); poll
[ "$KICKS" -eq 1 ] && [ "$(sget attempts)" = "1" ] && [ "$(sget next_allowed)" = "$((NOW+10+300))" ] && ok "episode: the next chronic episode's first failure backs off 300s (not a leftover long backoff)" || bad "next episode: kicks=$KICKS state='$(cat "$GC_TRIGGER_STATE" 2>/dev/null)'"

# (5) Knob edge: GC_RELEASE_MIN_STREAK=0 made "streak >= min" true for a HEALTHY streak of 0 — every
#     poll (288/day) eligible, no backoff (each run clears the streak, which resets attempts).
#     A minimum below 1 is unusable, not "always chronic".
[ "$(dec 0 20000 $SZ $ST $PCT $FL 0 $SL 1 1)" = "WAIT unmeasurable-input" ] && [ "$(dec 0 20000 $SZ $ST $PCT $FL 00 $SL 1 1)" = "WAIT unmeasurable-input" ] && ok "decision: min_streak 0 (or 00) → WAIT unmeasurable-input, never 'every healthy poll is chronic'" || bad "decision min_streak 0 got: '$(dec 0 20000 $SZ $ST $PCT $FL 0 $SL 1 1)'"
[ "$(dec 1 20000 $SZ $ST $PCT $FL 1 $SL 1 1)" = "KICK direct" ] && ok "decision: min_streak 1 is the smallest usable minimum (a single skip is chronic)" || bad "decision min_streak 1 got: '$(dec 1 20000 $SZ $ST $PCT $FL 1 $SL 1 1)'"
_mz_ok=1
for _min in 0 00 "" abc; do
  reset_main; AVAIL=20000; GC_RELEASE_MIN_STREAK="$_min"; printf '0 0\n' > "$GC_SKIP_STREAK_STATE"; poll
  [ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT unmeasurable-input" ] || { _mz_ok=0; echo "    (GC_RELEASE_MIN_STREAK='$_min' at streak 0: kicks=$KICKS dec='$(sdec)')"; }
done
[ "$_mz_ok" = "1" ] && ok "poll: GC_RELEASE_MIN_STREAK 0/00/empty/non-numeric at a healthy streak → no run, WAIT unmeasurable-input (3 polls in a row can no longer start 3 GCs)" || bad "poll: an unusable GC_RELEASE_MIN_STREAK let a healthy poll through"
unset _mz_ok _min

# (6) A backoff written under a clock that ran fast must not hold the trigger inert past its own cap.
reset_main; AVAIL=12486
printf 'poll=%s decision=WAIT backoff attempts=2 next_allowed=%s\n' "$((NOW-10))" "$((NOW+864000))" > "$GC_TRIGGER_STATE"
poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT backoff" ] && [ "$(sget next_allowed)" = "$((NOW+7200))" ] && ok "backoff: a next_allowed 10 days ahead is clamped to now+cap (7200s)" || bad "clamp: kicks=$KICKS state='$(cat "$GC_TRIGGER_STATE" 2>/dev/null)'"
GC_NOW_EPOCH=$((NOW+7200)); poll
[ "$KICKS" -eq 1 ] && ok "backoff: ...and the trigger resumes when the CAP elapses, not when the skewed timestamp does" || bad "clamp: still inert at now+cap (kicks=$KICKS state='$(cat "$GC_TRIGGER_STATE" 2>/dev/null)')"

# (7) The kill switch is a pause, not a reset: the recorded backoff survives GC_TRIGGER_ENABLED=0.
reset_main; AVAIL=12486
printf 'poll=%s decision=WAIT backoff attempts=3 next_allowed=%s\n' "$((NOW-10))" "$((NOW+1000))" > "$GC_TRIGGER_STATE"
GC_TRIGGER_ENABLED=0; poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "DISABLED" ] && [ "$(sget attempts)" = "3" ] && [ "$(sget next_allowed)" = "$((NOW+1000))" ] && ok "kill switch: DISABLED keeps attempts/next_allowed (re-enabling does not forget the backoff)" || bad "disabled state: '$(cat "$GC_TRIGGER_STATE" 2>/dev/null)'"
GC_TRIGGER_ENABLED=1; GC_NOW_EPOCH=$((NOW+10)); poll
[ "$KICKS" -eq 0 ] && [ "$(sdec)" = "WAIT backoff" ] && ok "kill switch: after re-enabling, the backoff is still in force" || bad "re-enabled: kicks=$KICKS dec='$(sdec)'"
reset_main; GC_TRIGGER_ENABLED=0; poll
[ "$(sdec)" = "DISABLED" ] && [ "$(sget attempts)" = "0" ] && ok "kill switch: with no prior state DISABLED starts from a clean record" || bad "disabled first: '$(cat "$GC_TRIGGER_STATE" 2>/dev/null)'"
reset_main; GC_TRIGGER_ENABLED=0; printf 'garbage\n' > "$GC_TRIGGER_STATE"; poll
[ "$(sget attempts)" = "0" ] && [ "$(sget next_allowed)" = "0" ] && ok "kill switch: an unreadable prior state is not trusted for its backoff (records 0/0)" || bad "disabled over garbage: '$(cat "$GC_TRIGGER_STATE" 2>/dev/null)'"

# (8) Cheapest-first inside the eligible path: a poll in its backoff window must not fork the `ps`
#     busy check (~1.2 s at load, 24×/h for nothing) — and the header's cost claim depends on it.
reset_main; AVAIL=12000; BUSY="backup-writer-running"
printf 'poll=%s decision=WAIT backoff attempts=2 next_allowed=%s\n' "$((NOW-10))" "$((NOW+600))" > "$GC_TRIGGER_STATE"
poll
[ "$KICKS" -eq 0 ] && [ "$(nreads busy)" -eq 0 ] && [ "$(sdec)" = "WAIT backoff" ] && ok "cost: inside a backoff window the release poll skips the ps busy check (busy calls=0), decision WAIT backoff" || bad "backoff before busy: kicks=$KICKS busy_calls=$(nreads busy) dec='$(sdec)'"
reset_main; AVAIL=12000; BUSY="backup-writer-running"; poll
[ "$(nreads busy)" -eq 1 ] && [[ "$(sdec)" == "WAIT staging-busy"* ]] && ok "cost: (control) with no backoff the release poll DOES run the busy check once" || bad "busy control: busy_calls=$(nreads busy) dec='$(sdec)'"
reset_main; AVAIL=20000; poll
[ "$(nreads busy)" -eq 0 ] && ok "cost: a DIRECT kick never runs the busy check (nothing is released on that path)" || bad "direct kick ran the busy check ($(nreads busy))"

# (9) A state that cannot be written is visible, not silent: WAIT-path writes used to fail without a
#     word (no heartbeat, no log line). Logged at most ~hourly, so 288 polls/day cannot flood the log.
if [ "$(id -u)" != "0" ]; then
  reset_main; AVAIL=7263
  printf 'poll=%s decision=WAIT x attempts=0 next_allowed=0\n' "$((NOW-10))" > "$GC_TRIGGER_STATE"; chmod 444 "$GC_TRIGGER_STATE"
  poll
  [ "$KICKS" -eq 0 ] && grep -q 'cannot write .* not recorded' "$DOLT_GC_MAINT_LOG" && ok "state write: a WAIT-path write that fails is logged (no more silent missing heartbeat)" || bad "silent WAIT write failure: kicks=$KICKS log='$(tail -2 "$DOLT_GC_MAINT_LOG" 2>/dev/null)'"
  : > "$DOLT_GC_MAINT_LOG"; GC_NOW_EPOCH=$((NOW+1800)); poll
  [ ! -s "$DOLT_GC_MAINT_LOG" ] && ok "state write: the same failure mid-hour is NOT logged again (throttled, no 288/day)" || bad "write-failure WARN not throttled: $(cat "$DOLT_GC_MAINT_LOG")"
  GC_NOW_EPOCH=$((NOW+3600)); poll
  grep -q 'cannot write .* not recorded' "$DOLT_GC_MAINT_LOG" && ok "state write: ...and logged again at the next hour" || bad "write-failure WARN never repeats"
  chmod 644 "$GC_TRIGGER_STATE"
  # an unreadable state that ALSO cannot be rewritten must not claim it reset it
  reset_main; AVAIL=20000; mkdir -p "$T/ro"; printf 'garbage\n' > "$T/ro/state"; GC_TRIGGER_STATE="$T/ro/state"; chmod 555 "$T/ro"; chmod 444 "$T/ro/state"
  poll
  [ "$KICKS" -eq 0 ] && ! grep -q 'reset to a clean record' "$DOLT_GC_MAINT_LOG" && grep -q 'cannot be rewritten' "$DOLT_GC_MAINT_LOG" && ok "state: an unreadable state that cannot be rewritten says so — it does not claim 'resetting it'" || bad "unrewritable unreadable state: kicks=$KICKS log='$(tail -2 "$DOLT_GC_MAINT_LOG" 2>/dev/null)'"
  chmod 755 "$T/ro"; chmod 644 "$T/ro/state"; rm -f "$T/ro/state"; rmdir "$T/ro"; GC_TRIGGER_STATE="$T/trigger.state"
fi

# (10) The REAL run body (until now only ever stubbed). It must hand the job GC_TRIGGERED_RUN=1 — the
#      literal 1, and NOT the library flag (a job that loaded as a library would do nothing and exit 0) —
#      and its exit status must reach the poll. Runs under the same bash the selftest runs under.
eval "$_REAL_RUN_MAINT"
cat > "$T/fakejob.sh" <<'FAKEJOB'
#!/bin/bash
printf 'GC_TRIGGERED_RUN=%s LIB=%s ARGS=%s\n' "${GC_TRIGGERED_RUN-<unset>}" "${DOLT_GC_MAINT_LIB-<unset>}" "$#" > "$FAKEJOB_OUT"
[ -n "${FAKEJOB_STREAK:-}" ] && printf '%s\n' "$FAKEJOB_STREAK" > "$GC_SKIP_STREAK_STATE"
exit "${FAKEJOB_RC:-0}"
FAKEJOB
chmod +x "$T/fakejob.sh"
export FAKEJOB_OUT="$T/fakejob.out"
_MAINT_SAVED="$MAINT"; MAINT="$T/fakejob.sh"
rm -f "$FAKEJOB_OUT"; GC_TRIGGERED_RUN=1 _trg_run_maintenance
[ "$(cat "$FAKEJOB_OUT" 2>/dev/null)" = "GC_TRIGGERED_RUN=1 LIB=<unset> ARGS=0" ] && ok "run body: the REAL _trg_run_maintenance hands the job GC_TRIGGERED_RUN=1, no library flag, no arguments" || bad "run body env: '$(cat "$FAKEJOB_OUT" 2>/dev/null)'"
rm -f "$FAKEJOB_OUT"; ( unset GC_TRIGGERED_RUN; _trg_run_maintenance )
[ "$(cat "$FAKEJOB_OUT" 2>/dev/null)" = "GC_TRIGGERED_RUN=<unset> LIB=<unset> ARGS=0" ] && ok "run body: (control) the marker comes from the CALL SITE prefix — the body itself sets nothing" || bad "run body control: '$(cat "$FAKEJOB_OUT" 2>/dev/null)'"
export FAKEJOB_RC=7; GC_TRIGGERED_RUN=1 _trg_run_maintenance; _rc=$?
[ "$_rc" -eq 7 ] && ok "run body: the job's exit status is returned (7)" || bad "run body rc: $_rc"
MAINT="$T/does-not-exist.sh"; GC_TRIGGERED_RUN=1 _trg_run_maintenance 2>/dev/null; _rc=$?
[ "$_rc" -ne 0 ] && ok "run body: a job that cannot start (missing script) is a nonzero status, not a silent 0" || bad "run body: missing job returned 0"
export FAKEJOB_RC=0
# ...and end to end through the poll with the REAL body: the poll's call site really passes the marker
# (it would not if `GC_TRIGGERED_RUN=1` were dropped from the call), and the job's clear is honoured.
MAINT="$T/fakejob.sh"
reset_main; AVAIL=12486; export FAKEJOB_STREAK="0 0"; rm -f "$FAKEJOB_OUT"; poll
[ "$(cat "$FAKEJOB_OUT" 2>/dev/null)" = "GC_TRIGGERED_RUN=1 LIB=<unset> ARGS=0" ] && [ "$(sget attempts)" = "0" ] && grep -q 'skip streak is cleared' "$DOLT_GC_MAINT_LOG" && ok "run body: poll → real body → job: the marker arrives, the job's clear ('0 0') is read back as cleared" || bad "poll→real body: out='$(cat "$FAKEJOB_OUT" 2>/dev/null)' state='$(cat "$GC_TRIGGER_STATE" 2>/dev/null)'"
reset_main; AVAIL=12486; export FAKEJOB_STREAK="" FAKEJOB_RC=127; rm -f "$FAKEJOB_OUT"; poll
[ "$(sget attempts)" = "1" ] && grep -q 'exited rc=127' "$DOLT_GC_MAINT_LOG" && ok "run body: poll → real body → a job that exits 127 leaves the streak standing → attempt counted, rc logged" || bad "poll→real body rc: state='$(cat "$GC_TRIGGER_STATE" 2>/dev/null)' log='$(grep 'trigger:' "$DOLT_GC_MAINT_LOG" | tail -1)'"
unset FAKEJOB_STREAK FAKEJOB_RC FAKEJOB_OUT _rc; MAINT="$_MAINT_SAVED"; unset _MAINT_SAVED; rm -f "$T/fakejob.sh" "$T/fakejob.out"
_trg_run_maintenance() { _stub_run; }   # back to the stub for the rest of the file

# ── the trigger is NOT a second way to delete, and does not export lib mode to its child ──
_code="$(grep -v '^[[:space:]]*#' "$TRIGGER")"
printf '%s\n' "$_code" | grep -Eq '(^|[^A-Za-z_])rm( |$)|rmdir|unlink|_gc_maybe_release_staging|_s3proof_' && bad "static: the trigger references a deletion/release/proof primitive — it must only DECIDE and start the job" || ok "static: no rm/rmdir/unlink, no release or S3-proof call in the trigger — deletion stays in the maintenance job"
printf '%s\n' "$_code" | grep -Eq 'export +DOLT_GC_MAINT_LIB' && bad "static: the trigger exports DOLT_GC_MAINT_LIB — the job it starts would load as a library and do nothing" || ok "static: DOLT_GC_MAINT_LIB is not exported (the started job runs main, not as a library)"
printf '%s\n' "$_code" | grep -Eq 'GC_TRIGGERED_RUN=1' && ok "static: the job is started with GC_TRIGGERED_RUN=1" || bad "static: GC_TRIGGERED_RUN=1 not passed to the started job"
/bin/bash -n "$TRIGGER" 2>/dev/null && ok "static: parses under /bin/bash (3.2) — the interpreter launchd runs it with" || bad "static: does not parse under /bin/bash 3.2"
unset _code

unset -f _avail_mb _trg_dir_mb _gc_release_busy _trg_run_maintenance _stub_run reset_main poll sget sdec dec nreads mangle_streak
case "$T" in "${TMPDIR:-/tmp}"/dolt-gc-trigger-selftest.*) rm -rf "$T" ;; esac

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
