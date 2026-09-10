#!/bin/bash
# dolt-gc-maintenance.selftest.sh — unit tests for the PURE decision logic of
# dolt-gc-maintenance.sh: prune window, per-run cap, backlog batching, over-cap
# circuit-break, skip-when-hot, backup-gate, and the weekly-flatten gate.
#
# Hermetic: sources the script as a LIBRARY (DOLT_GC_MAINT_LIB=1) so main() never
# runs, points the config/log at throwaway paths, and stubs the read-only counter.
# Real `bd prune` / `bd flatten` / Dolt are NEVER called; NOTHING is deleted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dolt-gc-maintenance.sh"

export DOLT_GC_MAINT_LIB=1
export DOLT_MAINT_CONF="/tmp/dolt-gc-maint-noconf-$$.env"   # nonexistent → no real toggle read
export DOLT_GC_MAINT_LOG="/tmp/dolt-gc-maint-selftest-$$.log"
export GC_SKIP_STREAK_STATE="/tmp/dolt-gc-maint-selftest-streak-$$.state"  # ga-azzfw:
  # throwaway — the real default lives under $CITY/.gc/runtime and must NEVER be
  # touched by a test run.
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-gc-maintenance.selftest.sh ==="

# ── _prune_plan: window respected + cap enforced + backlog + overcap ──────────────
# A) steady state — candidates only at the keep window, well under cap → single PRUNE.
_prune_dryrun_count() { case "$2" in 3) echo 72 ;; *) echo 0 ;; esac; }
p="$(_prune_plan /x 3 3000)"; [ "$p" = "PRUNE 3 72" ] && ok "steady: PRUNE keep-window (72<=cap) uses keep_days=3" || bad "steady got: '$p'"

# B) nothing closed past the window → NOOP (never prunes recent/open work).
_prune_dryrun_count() { echo 0; }
p="$(_prune_plan /x 3 3000)"; [ "$p" = "NOOP 0 0" ] && ok "empty: NOOP" || bad "empty got: '$p'"

# C) backlog > cap at keep, but an older slice fits → BATCH the OLDEST slice under cap.
#    keep=3: count(3d)=9000 (>cap); count(6d)=5000 (>cap); count(9d)=2500 (<=cap) → BATCH 9.
_prune_dryrun_count() { case "$2" in 3) echo 9000 ;; 6) echo 5000 ;; 9) echo 2500 ;; *) echo 0 ;; esac; }
p="$(_prune_plan /x 3 3000)"; [ "$p" = "BATCH 9 2500" ] && ok "backlog: BATCH oldest slice that fits under cap (drains over cycles)" || bad "backlog got: '$p'"

# D) uniform huge backlog — even the oldest slice exceeds cap → OVERCAP (never over-delete).
_prune_dryrun_count() { echo 50000; }
p="$(_prune_plan /x 3 3000)"; [ "$p" = "OVERCAP 0 50000" ] && ok "overcap: SKIP + escalate (never exceed cap in one txn)" || bad "overcap got: '$p'"

# E) cap boundary — exactly at cap counts as within cap → single PRUNE.
_prune_dryrun_count() { case "$2" in 3) echo 3000 ;; *) echo 0 ;; esac; }
p="$(_prune_plan /x 3 3000)"; [ "$p" = "PRUNE 3 3000" ] && ok "boundary: count==cap → single PRUNE" || bad "boundary got: '$p'"

# F) window knob is honored — a different keep_days feeds the age straight through.
_prune_dryrun_count() { case "$2" in 7) echo 10 ;; *) echo 0 ;; esac; }
p="$(_prune_plan /x 7 3000)"; [ "$p" = "PRUNE 7 10" ] && ok "window: PRUNE_KEEP_DAYS=7 respected" || bad "window got: '$p'"

# ── _should_skip_hot: skip-when-hot ───────────────────────────────────────────────
_should_skip_hot 200 150 && ok "hot: cpu 200 > 150 → skip prune" || bad "hot: 200>150 should skip"
_should_skip_hot 40  150 && bad "cool: 40 should NOT skip" || ok "cool: cpu 40 < 150 → proceed"
_should_skip_hot ""  150 && bad "unknown cpu should fail-open" || ok "unknown cpu → proceed (fail-open; probe is the harder gate)"

# _dolt_cpu_pct must normalize a LOCALE decimal (comma OR dot) to a bare integer, so a
# hot reading like "194,3%" actually trips skip-when-hot (regression: pt_BR comma).
_gc_dolt_cpu_pct() { echo "194,3"; }   # stub the shared probe's ps reader (pt_BR format)
n="$(_dolt_cpu_pct)"; [ "$n" = "194" ] && ok "cpu locale: '194,3' → 194 (comma stripped)" || bad "cpu locale got: '$n'"
_should_skip_hot "$n" 150 && ok "cpu locale: normalized 194 > 150 → skip (hot-check fires)" || bad "cpu locale: 194 should skip"
_gc_dolt_cpu_pct() { echo "62.4"; }    # dot-locale variant
n="$(_dolt_cpu_pct)"; [ "$n" = "62" ] && ok "cpu locale: '62.4' → 62 (dot stripped)" || bad "cpu locale dot got: '$n'"
unset -f _gc_dolt_cpu_pct

# ── _gc_headroom_ok: disk headroom gate before dolt_gc() (ga-sfj3i.4) ────────────
_gc_headroom_ok 500 200 250 && ok "headroom: avail=500 size=200 required=500 (250%) → boundary ok (>=)" || bad "headroom: 500>=500 should pass"
_gc_headroom_ok 499 200 250 && bad "headroom: avail=499 < required=500 should fail" || ok "headroom: avail=499 < required=500 → not enough room"
_gc_headroom_ok 10000 200 250 && ok "headroom: plenty of room → ok" || bad "headroom: 10000 avail should pass"
_gc_headroom_ok ""    200 250 && bad "headroom: empty avail should fail-closed" || ok "headroom: unmeasurable avail (empty) → fail-closed, not proceed"
_gc_headroom_ok 500   ""  250 && bad "headroom: empty size should fail-closed" || ok "headroom: unmeasurable size (empty) → fail-closed, not proceed"
_gc_headroom_ok 500   200 ""  && bad "headroom: empty pct should fail-closed" || ok "headroom: unmeasurable pct (empty) → fail-closed, not proceed"
_gc_headroom_ok "abc" 200 250 && bad "headroom: non-numeric avail should fail-closed" || ok "headroom: non-numeric avail → fail-closed"

# ── _gc_floor_ok: absolute Dolt-CRITICAL floor, independent of the pct gate (ga-3euoj) ──
_gc_floor_ok 9300 6228 3072 && ok "floor: avail=9300 size=6228 floor=3072 → boundary ok (>=)" || bad "floor: 9300>=9300 should pass"
_gc_floor_ok 9299 6228 3072 && bad "floor: avail=9299 < required=9300 should fail" || ok "floor: avail=9299 < required=9300 → not enough room"
_gc_floor_ok 20000 6228 3072 && ok "floor: plenty of room → ok" || bad "floor: 20000 avail should pass"
_gc_floor_ok ""    6228 3072 && bad "floor: empty avail should fail-closed" || ok "floor: unmeasurable avail (empty) → fail-closed, not proceed"
_gc_floor_ok 9300  ""   3072 && bad "floor: empty size should fail-closed" || ok "floor: unmeasurable size (empty) → fail-closed, not proceed"
_gc_floor_ok 9300  6228 ""   && bad "floor: empty floor should fail-closed" || ok "floor: unmeasurable floor (empty) → fail-closed, not proceed"
_gc_floor_ok "abc" 6228 3072 && bad "floor: non-numeric avail should fail-closed" || ok "floor: non-numeric avail → fail-closed"
# the small-hq case this check exists for: at size=1000MB, the pct gate alone (200%)
# only demands avail>=2000MB, leaving just 1000MB of margin — under the 3GB floor.
_gc_floor_ok 2000 1000 3072 && bad "floor: small-hq case must still enforce the 3GB floor" || ok "floor: small hq (1000MB) still needs avail>=4072MB, not just the pct gate's 2000MB"

# ── _resolve_gc_min_free_pct: prune-conditional default, explicit pin always wins (ga-3euoj) ──
r="$(_resolve_gc_min_free_pct "" 0 200 280)"; [ "$r" = "200" ] && ok "resolve: prune disabled → base (200)" || bad "resolve prune-off got: '$r'"
r="$(_resolve_gc_min_free_pct "" 1 200 280)"; [ "$r" = "280" ] && ok "resolve: prune enabled → with-prune (280)" || bad "resolve prune-on got: '$r'"
r="$(_resolve_gc_min_free_pct "999" 0 200 280)"; [ "$r" = "999" ] && ok "resolve: explicit pin wins over prune-disabled base" || bad "resolve pin (prune off) got: '$r'"
r="$(_resolve_gc_min_free_pct "999" 1 200 280)"; [ "$r" = "999" ] && ok "resolve: explicit pin wins over prune-enabled with-prune" || bad "resolve pin (prune on) got: '$r'"

# ── measured constants — pin them down so a future edit can't silently drift the
#    calibration without updating its justifying comment (ga-3euoj) ──────────────
[ "$GC_MIN_FREE_PCT_BASE" = "200" ] && ok "constant: GC_MIN_FREE_PCT_BASE=200 (665 real runs, worst ratio 1.000)" || bad "GC_MIN_FREE_PCT_BASE drifted: '$GC_MIN_FREE_PCT_BASE'"
[ "$GC_MIN_FREE_PCT_WITH_PRUNE" = "280" ] && ok "constant: GC_MIN_FREE_PCT_WITH_PRUNE=280 (235 real runs, worst ratio 1.7358)" || bad "GC_MIN_FREE_PCT_WITH_PRUNE drifted: '$GC_MIN_FREE_PCT_WITH_PRUNE'"
[ "$GC_MIN_FREE_ABS_MB" = "3072" ] && ok "constant: GC_MIN_FREE_ABS_MB=3072 (Dolt CRITICAL floor, ga-vs55)" || bad "GC_MIN_FREE_ABS_MB drifted: '$GC_MIN_FREE_ABS_MB'"

# ── _avail_mb: free-space read against the real filesystem ──────────────────────
# No mock — matches this file's own _backup_fresh tests below, which also exercise
# real filesystem paths rather than stubbing find/stat.
m="$(_avail_mb /tmp)"
case "$m" in
  ''|*[!0-9]*) bad "avail_mb: expected a non-negative integer for /tmp, got '$m'" ;;
  *) ok "avail_mb: real path /tmp → numeric MB ($m)" ;;
esac
m="$(_avail_mb /this/path/does/not/exist/ga-sfj3i-4-selftest)"
[ -z "$m" ] && ok "avail_mb: nonexistent path → empty (never a fabricated 0 or number — error and empty must not read the same as 'plenty of room')" || bad "avail_mb: nonexistent path got: '$m'"

# ── _backup_fresh: prune is gated on a recent backup ─────────────────────────────
TMPB="$(mktemp -d)"; mkdir -p "$TMPB/hq"
_backup_fresh "$TMPB" hq 26 && ok "backup: fresh staging dir within window → allow" || bad "backup: fresh dir should pass"
touch -t 202001010000 "$TMPB/hq" 2>/dev/null
_backup_fresh "$TMPB" hq 26 && bad "backup: stale dir should fail" || ok "backup: stale dir → gate blocks prune"
_backup_fresh "$TMPB" nope 26 && bad "backup: missing db dir should fail" || ok "backup: missing db dir → gate blocks prune"
rm -rf "$TMPB"

# ── _flatten_due: weekly + quiet-hour + once-per-week ─────────────────────────────
SENT="$(mktemp -u)"
_flatten_due "$SENT" 0 3 7 5  2026-27 && bad "flatten disabled should not run" || ok "flatten: FLATTEN_ENABLED=0 → not due"
_flatten_due "$SENT" 1 3 7 5  2026-27 && ok "flatten: enabled + quiet hour(5) + new week → due" || bad "flatten: should be due"
_flatten_due "$SENT" 1 3 7 12 2026-27 && bad "flatten outside quiet hour should not run" || ok "flatten: hour 12 outside [3,7) → not due"
echo "2026-27" > "$SENT"
_flatten_due "$SENT" 1 3 7 5  2026-27 && bad "flatten already ran this week should not run" || ok "flatten: same-week sentinel → not due (>=1/week)"
_flatten_due "$SENT" 1 3 7 5  2026-28 && ok "flatten: next ISO-week → due again" || bad "flatten: new week should be due"
rm -f "$SENT"

# ── _skip_streak_parse / _skip_streak_next: pure consecutive-skip counter (ga-azzfw) ──
p="$(_skip_streak_parse "")"; [ "$p" = "0 0" ] && ok "streak parse: empty/missing state → '0 0'" || bad "streak parse empty got: '$p'"
p="$(_skip_streak_parse "2 0")"; [ "$p" = "2 0" ] && ok "streak parse: well-formed state round-trips" || bad "streak parse got: '$p'"
p="$(_skip_streak_parse "garbage")"; [ "$p" = "0 0" ] && ok "streak parse: corrupt state fails SAFE to '0 0' (worst case: one delayed alert, never a lost one)" || bad "streak parse corrupt got: '$p'"

n="$(_skip_streak_next 0 0 3)"; [ "$n" = "1 0 0" ] && ok "streak next: 1st skip → count=1, no alert" || bad "streak next 1st got: '$n'"
n="$(_skip_streak_next 1 0 3)"; [ "$n" = "2 0 0" ] && ok "streak next: 2nd skip → count=2, no alert" || bad "streak next 2nd got: '$n'"
n="$(_skip_streak_next 2 0 3)"; [ "$n" = "3 1 1" ] && ok "streak next: 3rd skip → count=3, ALERTS, marks alerted" || bad "streak next 3rd got: '$n'"
n="$(_skip_streak_next 3 1 3)"; [ "$n" = "4 1 0" ] && ok "streak next: 4th skip (same streak) → count=4, no RE-alert" || bad "streak next 4th got: '$n'"

# ── _gc_no_effect: dolt_gc() ran but hq didn't shrink (ga-azzfw requirement 4) ────────
_gc_no_effect 1000 800  && bad "no-effect: 800<1000 (shrank) should NOT flag" || ok "no-effect: store shrank → not flagged"
_gc_no_effect 1000 1000 && ok "no-effect: post==pre (zero shrinkage) → flagged" || bad "no-effect: 1000==1000 should flag"
_gc_no_effect 1000 1200 && ok "no-effect: post>pre (grew) → flagged" || bad "no-effect: 1200>1000 should flag"
_gc_no_effect ""   800  && bad "no-effect: unmeasurable pre should fail-open (never flag)" || ok "no-effect: unmeasurable pre → fail-open, not flagged"
_gc_no_effect 1000 ""   && bad "no-effect: unmeasurable post should fail-open (never flag)" || ok "no-effect: unmeasurable post → fail-open, not flagged"

# ── _handle_gc_skip_streak / _clear_skip_streak: end-to-end streak + one-alert-per-
#    streak behavior (ga-azzfw's own stated test: "3 skips geram 1 alerta, skip-skip-
#    run zera o contador sem alertar"). Redefine the two side-effecting wrappers so no
#    real notify/mail ever fires — same idiom this file already uses to stub
#    _prune_dryrun_count (see memory mutation-check-notify-code-neutralize: the stub
#    must intercept the wrapper CALLED by the code under test, which it does here).
ALERT_NOTIFY_CALLS=0; ALERT_MAIL_CALLS=0
_dolt_gc_notify() { ALERT_NOTIFY_CALLS=$((ALERT_NOTIFY_CALLS+1)); }
_dolt_gc_mail_mayor() { ALERT_MAIL_CALLS=$((ALERT_MAIL_CALLS+1)); }

rm -f "$GC_SKIP_STREAK_STATE"
_handle_gc_skip_streak 6000 1000 12000   # skip 1
_handle_gc_skip_streak 6000 1000 12000   # skip 2
[ "$ALERT_NOTIFY_CALLS" -eq 0 ] && [ "$ALERT_MAIL_CALLS" -eq 0 ] && ok "skip-streak: no alert yet after 2 consecutive skips" || bad "skip-streak: alert fired too early (notify=$ALERT_NOTIFY_CALLS mail=$ALERT_MAIL_CALLS)"
_handle_gc_skip_streak 6000 1000 12000   # skip 3 → should alert exactly once
[ "$ALERT_NOTIFY_CALLS" -eq 1 ] && [ "$ALERT_MAIL_CALLS" -eq 1 ] && ok "skip-streak: 3 consecutive skips → exactly 1 alert (notify+mail)" || bad "skip-streak: expected 1+1, got notify=$ALERT_NOTIFY_CALLS mail=$ALERT_MAIL_CALLS"
_handle_gc_skip_streak 6000 1000 12000   # skip 4, same streak → must NOT re-alert
[ "$ALERT_NOTIFY_CALLS" -eq 1 ] && [ "$ALERT_MAIL_CALLS" -eq 1 ] && ok "skip-streak: 4th consecutive skip does not re-alert (one alert per streak)" || bad "skip-streak: re-alerted on 4th skip (notify=$ALERT_NOTIFY_CALLS mail=$ALERT_MAIL_CALLS)"
s="$(_read_skip_streak "$GC_SKIP_STREAK_STATE")"; [ "$s" = "4 1" ] && ok "skip-streak: state file reads back '4 1' after 4 skips" || bad "skip-streak: state got '$s'"

# skip-skip-run: 2 skips then a clear (simulating dolt_gc finally being attempted) →
# counter resets to 0 and NEVER alerts (never reached the threshold).
rm -f "$GC_SKIP_STREAK_STATE"
ALERT_NOTIFY_CALLS=0; ALERT_MAIL_CALLS=0
_handle_gc_skip_streak 6000 1000 12000   # skip 1
_handle_gc_skip_streak 6000 1000 12000   # skip 2
_clear_skip_streak "$GC_SKIP_STREAK_STATE" "selftest: simulated dolt_gc attempt"
s="$(_read_skip_streak "$GC_SKIP_STREAK_STATE")"; [ "$s" = "0 0" ] && ok "skip-skip-run: counter resets to '0 0' on clear" || bad "skip-skip-run: state got '$s'"
[ "$ALERT_NOTIFY_CALLS" -eq 0 ] && [ "$ALERT_MAIL_CALLS" -eq 0 ] && ok "skip-skip-run: never alerted (streak cleared before reaching threshold)" || bad "skip-skip-run: unexpectedly alerted (notify=$ALERT_NOTIFY_CALLS mail=$ALERT_MAIL_CALLS)"
# a NEW streak after the clear can alert again — one alert per streak, not one ever.
_handle_gc_skip_streak 6000 1000 12000
_handle_gc_skip_streak 6000 1000 12000
_handle_gc_skip_streak 6000 1000 12000
[ "$ALERT_NOTIFY_CALLS" -eq 1 ] && [ "$ALERT_MAIL_CALLS" -eq 1 ] && ok "skip-streak: a NEW streak after a clear alerts again at the 3rd skip" || bad "skip-streak: new streak got notify=$ALERT_NOTIFY_CALLS mail=$ALERT_MAIL_CALLS"
rm -f "$GC_SKIP_STREAK_STATE"
unset -f _dolt_gc_notify _dolt_gc_mail_mayor

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
