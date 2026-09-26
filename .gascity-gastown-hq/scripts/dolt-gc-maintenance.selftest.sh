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

# ═══ ga-btnq6h: guarded release of hq's LOCAL backup staging for the dolt_gc window ═══
# The release is the only destructive act in dolt-gc-maintenance.sh, so the tests below
# pin the property that matters: EVERY refusal leaves the staging directory on disk.
# Hermetic — a throwaway tree stands in for $CITY/.dolt-backup; the S3 proof, the Dolt
# probe, notify/mail, `ps` and `du` are stubbed; the real aws/dolt/S3 are never touched.

# ── _gc_release_decision: pure arithmetic, fail-closed on anything unmeasurable ──────
d() { _gc_release_decision "$@"; }
[ "$(d 53 9000 8800 15400 6 2048)" = "RELEASE" ] && ok "release-decision: chronic streak + freeing staging clears the gate → RELEASE" || bad "release-decision happy got: '$(d 53 9000 8800 15400 6 2048)'"
[ "$(d 6 9000 8800 15400 6 2048)" = "RELEASE" ] && ok "release-decision: streak exactly at the minimum is enough (boundary)" || bad "release-decision streak==min got: '$(d 6 9000 8800 15400 6 2048)'"
[ "$(d 5 9000 8800 15400 6 2048)" = "REFUSE streak-too-short" ] && ok "release-decision: one cycle short of chronic → REFUSE streak-too-short" || bad "release-decision short-streak got: '$(d 5 9000 8800 15400 6 2048)'"
[ "$(d 53 6000 8800 15400 6 2048)" = "REFUSE would-not-unblock-gc" ] && ok "release-decision: freeing the staging would NOT clear the gate → REFUSE (never delete for nothing)" || bad "release-decision no-unblock got: '$(d 53 6000 8800 15400 6 2048)'"
# exact edge of avail+staging >= required+slack (15400+2048 = 17448)
[ "$(d 53 8648 8800 15400 6 2048)" = "RELEASE" ] && [ "$(d 53 8647 8800 15400 6 2048)" = "REFUSE would-not-unblock-gc" ] && ok "release-decision: avail+staging vs required+slack is exact to the MB" || bad "release-decision edge: '$(d 53 8648 8800 15400 6 2048)' / '$(d 53 8647 8800 15400 6 2048)'"
[ "$(d 53 9000 0 15400 6 2048)" = "REFUSE no-staging" ] && ok "release-decision: zero-size staging → REFUSE no-staging" || bad "release-decision zero-staging got: '$(d 53 9000 0 15400 6 2048)'"
_dec_with() {   # _dec_with <1-based arg position> <value> — happy-path args with ONE input replaced
  local a=(53 9000 8800 15400 6 2048)
  a[$(( $1 - 1 ))]="$2"
  _gc_release_decision "${a[@]}"
}
_bad_all=1
for _pos in 1 2 3 4 5 6; do
  for _val in "" "abc" "-1" "1.5" "12MB"; do
    [ "$(_dec_with "$_pos" "$_val")" = "REFUSE unmeasurable-input" ] || { _bad_all=0; echo "    (arg $_pos='$_val' was not refused as unmeasurable)"; }
  done
done
unset -f _dec_with
[ "$_bad_all" = "1" ] && ok "release-decision: every input blank/non-numeric/negative/decimal → REFUSE unmeasurable-input (a failed read never looks like 'plenty of room')" || bad "release-decision: some unmeasurable input was not refused"
unset _pos _val _bad_all

# ── _gc_release_cooldown_ok: state file is the only memory; anything odd → not ok ─────
CT="$(mktemp -d "${TMPDIR:-/tmp}/dolt-gc-release-selftest.XXXXXX")"
[ -n "$CT" ] && [ -d "$CT" ] || { bad "release: mktemp failed — remaining release tests skipped"; CT=""; }
if [ -n "$CT" ]; then
  _gc_release_cooldown_ok "$CT/none.state" 168 1000000 && ok "cooldown: never released (no state file) → ok" || bad "cooldown: absent state should be ok"
  printf '%s\n' 1000000 > "$CT/s.state"
  _gc_release_cooldown_ok "$CT/s.state" 168 $((1000000 + 3600)) && bad "cooldown: 1h after a release must NOT be ok" || ok "cooldown: 1h after a release → not ok"
  _gc_release_cooldown_ok "$CT/s.state" 168 $((1000000 + 168*3600)) && ok "cooldown: exactly the cooldown later → ok (boundary)" || bad "cooldown: boundary should be ok"
  _gc_release_cooldown_ok "$CT/s.state" 168 $((1000000 + 168*3600 - 1)) && bad "cooldown: 1s early must NOT be ok" || ok "cooldown: 1s before the boundary → not ok"
  _gc_release_cooldown_ok "$CT/s.state" 168 999000 && bad "cooldown: clock ran backwards must NOT be ok" || ok "cooldown: clock behind the recorded release → not ok (cannot tell)"
  printf 'garbage\n' > "$CT/g.state"
  _gc_release_cooldown_ok "$CT/g.state" 168 9999999999 && bad "cooldown: unreadable state must NOT be ok" || ok "cooldown: state exists but is not an epoch → not ok (fail closed)"
  : > "$CT/e.state"
  _gc_release_cooldown_ok "$CT/e.state" 168 9999999999 && bad "cooldown: empty state file must NOT be ok" || ok "cooldown: empty state file → not ok (fail closed)"
  _gc_release_cooldown_ok "$CT/s.state" "" 9999999999 && bad "cooldown: blank hours must NOT be ok" || ok "cooldown: non-numeric hours → not ok"
  _gc_release_cooldown_ok "$CT/s.state" 168 "" && bad "cooldown: blank clock must NOT be ok" || ok "cooldown: non-numeric now → not ok"
fi

# ── _gc_release_writer_active: real function, `ps` stubbed. Only a clean "no such
#    process" is "not active"; a match OR an unreadable process table is "active". ──
_ps_out=""; _ps_rc=0
ps() { printf '%s' "$_ps_out"; return "$_ps_rc"; }
_wa() { _gc_release_writer_active && echo active || echo idle; }
_ps_out=$'/sbin/launchd\n/bin/bash /Users/athos/gt/.gascity-gastown-hq/scripts/dolt-gc-maintenance.sh\n/usr/bin/python3 -m pytest\n'; _ps_rc=0
[ "$(_wa)" = "idle" ] && ok "writer-active: benign process table (incl. dolt-gc-maintenance.sh itself) → idle" || bad "writer-active: false positive on a benign table"
_ps_out=$'/bin/bash /x/packs/town-deltas/assets/scripts/mol-dog-backup.sh\n'
[ "$(_wa)" = "active" ] && ok "writer-active: mol-dog-backup.sh running → active" || bad "writer-active: missed mol-dog-backup.sh"
_ps_out=$'/bin/bash /Users/athos/gt/.gascity-gastown-hq/scripts/dolt-s3-backup.sh\n'
[ "$(_wa)" = "active" ] && ok "writer-active: nightly dolt-s3-backup.sh running → active" || bad "writer-active: missed dolt-s3-backup.sh"
_ps_out=$'dolt backup sync hq-backup\n'
[ "$(_wa)" = "active" ] && ok "writer-active: bare 'dolt backup sync' CLI → active" || bad "writer-active: missed the dolt backup sync CLI"
_ps_out=$'dolt --host 127.0.0.1 --user root --no-tls sql -q USE `hq`; CALL DOLT_BACKUP(\'sync\', \'hq-backup\');\n'
[ "$(_wa)" = "active" ] && ok "writer-active: server-mediated CALL DOLT_BACKUP('sync') → active" || bad "writer-active: missed the server-mediated backup sync"
_ps_out=$'/bin/bash /x/scripts/dolt-backup-reseed.sh\n'
[ "$(_wa)" = "active" ] && ok "writer-active: reseed running → active" || bad "writer-active: missed dolt-backup-reseed.sh"
_ps_out=$'/bin/bash /x/scripts/dolt-s3-backup.selftest.sh\n/bin/bash /x/scripts/dolt-backup-reseed.selftest.sh\n'
[ "$(_wa)" = "idle" ] && ok "writer-active: a *.selftest.sh of a backup script is NOT a writer (no false block)" || bad "writer-active: selftest wrongly counted as a writer"
_ps_out=""; _ps_rc=0
[ "$(_wa)" = "active" ] && ok "writer-active: EMPTY process table → active (cannot tell = busy)" || bad "writer-active: empty ps must fail closed"
_ps_out=$'/sbin/launchd\n'; _ps_rc=1
[ "$(_wa)" = "active" ] && ok "writer-active: ps itself failing → active (cannot tell = busy)" || bad "writer-active: ps failure must fail closed"
unset -f ps _wa; unset _ps_out _ps_rc

if [ -n "$CT" ]; then
  # ── _gc_release_target: path-safety — only a real hq copy under a root named .dolt-backup ──
  mkstage() {  # mkstage <root> <db> [nomanifest]
    mkdir -p "$1/$2"; [ "${3:-}" = "nomanifest" ] || printf '5:__DOLT__:lock:root:gcgen\n' > "$1/$2/manifest"
    dd if=/dev/zero of="$1/$2/tablefile" bs=1024 count=64 2>/dev/null
  }
  R="$CT/city/.dolt-backup"; mkstage "$R" hq
  [ "$(_gc_release_target "$R" hq)" = "$R/hq" ] && ok "target: a real hq copy with a manifest under .dolt-backup → releasable" || bad "target: happy path got '$(_gc_release_target "$R" hq)'"
  mkstage "$CT/city2/.dolt-backup" hq nomanifest
  _gc_release_target "$CT/city2/.dolt-backup" hq >/dev/null && bad "target: a dir with no manifest must NOT be releasable" || ok "target: no manifest (not a backup copy) → refused"
  mkstage "$CT/city3/backups" hq
  _gc_release_target "$CT/city3/backups" hq >/dev/null && bad "target: root not named .dolt-backup must be refused" || ok "target: root not literally named .dolt-backup → refused"
  _gc_release_target ".dolt-backup" hq >/dev/null && bad "target: relative root must be refused" || ok "target: relative root → refused (never resolved against CWD)"
  for _db in "" "../x" "hq/.." "a b" "hq.new" "h/q" ".."; do
    _gc_release_target "$R" "$_db" >/dev/null && bad "target: db '$_db' must be refused" || ok "target: db name '$_db' (not a plain identifier) → refused"
  done
  unset _db
  mkdir -p "$CT/city4/.dolt-backup" "$CT/elsewhere/hq"; printf 'm\n' > "$CT/elsewhere/hq/manifest"
  ln -s "$CT/elsewhere/hq" "$CT/city4/.dolt-backup/hq"
  _gc_release_target "$CT/city4/.dolt-backup" hq >/dev/null && bad "target: a SYMLINKED hq must be refused" || ok "target: hq is a symlink → refused (would delete outside the staging root)"
  _gc_release_target "$R" nosuchdb >/dev/null && bad "target: absent db must be refused" || ok "target: absent dir → refused"

  # ── _gc_release_busy: lock / reseed residue / running writer each veto ──────────────────
  BUSYSTAGE="$CT/busy/.dolt-backup"; mkstage "$BUSYSTAGE" hq
  GC_RELEASE_BACKUP_LOCKDIR="$CT/busy/nightly.lock.d"
  _gc_release_writer_active() { return 1; }   # nothing running
  _gc_release_busy "$BUSYSTAGE/hq" >/dev/null && bad "busy: nothing in use should be NOT busy" || ok "busy: lock absent, no residue, no writer → free"
  mkdir "$GC_RELEASE_BACKUP_LOCKDIR"
  [ "$(_gc_release_busy "$BUSYSTAGE/hq")" = "nightly-backup-lock-held" ] && ok "busy: nightly backup lock held → busy" || bad "busy: lock not detected"
  rmdir "$GC_RELEASE_BACKUP_LOCKDIR"
  mkdir "$BUSYSTAGE/hq.new"
  [ "$(_gc_release_busy "$BUSYSTAGE/hq")" = "reseed-residue-present" ] && ok "busy: hq.new reseed residue present → busy" || bad "busy: .new residue not detected"
  rmdir "$BUSYSTAGE/hq.new"; mkdir "$BUSYSTAGE/hq.old"
  [ "$(_gc_release_busy "$BUSYSTAGE/hq")" = "reseed-residue-present" ] && ok "busy: hq.old reseed residue present → busy" || bad "busy: .old residue not detected"
  rmdir "$BUSYSTAGE/hq.old"
  _gc_release_writer_active() { return 0; }
  [ "$(_gc_release_busy "$BUSYSTAGE/hq")" = "backup-writer-running" ] && ok "busy: a backup writer is running → busy" || bad "busy: running writer not detected"

  # ── _gc_maybe_release_staging end to end: the S3 proof, probe, notify/mail, du, clock are
  #    stubs; the filesystem, state file, streak file, logging and ordering are REAL. ──────
  PROOF_CALLS=0; PROOF_RC=0; PROOF_SIDE=""
  _s3proof_repair_then_prove() { PROOF_CALLS=$((PROOF_CALLS+1)); [ -n "$PROOF_SIDE" ] && eval "$PROOF_SIDE"; return "$PROOF_RC"; }
  PROBE_RC=0; gc_dolt_probe() { return "$PROBE_RC"; }
  NOTIFY_N=0; MAIL_N=0
  _dolt_gc_notify() { NOTIFY_N=$((NOTIFY_N+1)); }
  _dolt_gc_mail_mayor() { MAIL_N=$((MAIL_N+1)); }
  FAKE_STAGING_MB=8800
  du() { if [ "${1:-}" = "-sm" ]; then printf '%s\t%s\n' "$FAKE_STAGING_MB" "${2:-}"; else command du "$@"; fi; }
  _gc_release_writer_active() { return 1; }

  GC_NOW_EPOCH=2000000000
  reset_release() {   # fresh staging + clean state for each scenario
    rm -rf "$CT/rel"; mkdir -p "$CT/rel"
    mkstage "$CT/rel/.dolt-backup" hq
    BACKUP_STAGING="$CT/rel/.dolt-backup"; DB="hq"
    GC_RELEASE_STATE="$CT/rel/release.state"; GC_RELEASE_BACKUP_LOCKDIR="$CT/rel/nightly.lock.d"
    GC_SKIP_STREAK_STATE="$CT/rel/streak.state"; printf '53 1\n' > "$GC_SKIP_STREAK_STATE"
    GC_RELEASE_STAGING_ENABLED=1; GC_RELEASE_STAGING_DRYRUN=0
    GC_RELEASE_MIN_STREAK=6; GC_RELEASE_SLACK_MB=2048; GC_RELEASE_COOLDOWN_H=168
    PROOF_CALLS=0; PROOF_RC=0; PROOF_SIDE=""; PROBE_RC=0; NOTIFY_N=0; MAIL_N=0
    _gc_release_writer_active() { return 1; }
  }
  STAGE_DIR() { echo "$CT/rel/.dolt-backup/hq"; }
  MAYBE() { _gc_maybe_release_staging 7900 9000 15400 >/dev/null 2>&1; }   # size avail required

  reset_release
  if MAYBE && [ ! -e "$(STAGE_DIR)" ]; then ok "release: chronic skip + S3 proven + nothing busy → staging REMOVED, returns 0"; else bad "release: happy path did not release"; fi
  [ "$PROOF_CALLS" -eq 1 ] && ok "release: the S3 proof ran exactly once" || bad "release: proof calls=$PROOF_CALLS"
  [ "$(cat "$GC_RELEASE_STATE" 2>/dev/null)" = "2000000000" ] && ok "release: cooldown state stamped with the release time" || bad "release: state got '$(cat "$GC_RELEASE_STATE" 2>/dev/null)'"
  [ "$NOTIFY_N" -eq 1 ] && [ "$MAIL_N" -eq 1 ] && ok "release: exactly one notify + one mail to the Mayor" || bad "release: notify=$NOTIFY_N mail=$MAIL_N"
  [ -d "$CT/rel/.dolt-backup" ] && ok "release: only hq was removed — the .dolt-backup root itself is untouched" || bad "release: the staging ROOT was removed"
  # a second release right after is blocked by the cooldown and never reaches the proof
  mkstage "$CT/rel/.dolt-backup" hq; PROOF_CALLS=0
  if ! MAYBE && [ -d "$(STAGE_DIR)" ] && [ "$PROOF_CALLS" -eq 0 ]; then ok "release: a second attempt inside the cooldown is refused BEFORE the (slow, aws) proof and deletes nothing"; else bad "release: cooldown did not stop the second release (calls=$PROOF_CALLS)"; fi

  refuse_case() {  # refuse_case <label> <expected-proof-calls>  (caller sets the scenario)
    local label="$1" want_calls="$2"
    if ! MAYBE && [ -d "$(STAGE_DIR)" ] && [ -s "$(STAGE_DIR)/manifest" ] && [ "$PROOF_CALLS" -eq "$want_calls" ] && [ "$NOTIFY_N" -eq 0 ]; then
      ok "refuse: $label → staging INTACT, proof calls=$want_calls, no notification"
    else
      bad "refuse: $label (staging_exists=$([ -d "$(STAGE_DIR)" ] && echo y || echo N) proof_calls=$PROOF_CALLS want=$want_calls notify=$NOTIFY_N)"
    fi
  }
  reset_release; GC_RELEASE_STAGING_ENABLED=0;             refuse_case "kill switch GC_RELEASE_STAGING_ENABLED=0" 0
  reset_release; printf '5 0\n' > "$GC_SKIP_STREAK_STATE"; refuse_case "streak below the minimum (not chronic)" 0
  reset_release; rm -f "$GC_SKIP_STREAK_STATE";            refuse_case "no streak state at all (unreadable = not chronic)" 0
  reset_release; printf 'junk\n' > "$GC_SKIP_STREAK_STATE"; refuse_case "garbled streak state" 0
  reset_release; FAKE_STAGING_MB=100;                       refuse_case "freeing it would not clear the gate" 0; FAKE_STAGING_MB=8800
  reset_release; printf '%s\n' 1999999999 > "$GC_RELEASE_STATE"; refuse_case "inside the cooldown" 0
  reset_release; printf 'x\n' > "$GC_RELEASE_STATE";         refuse_case "cooldown state unreadable" 0
  reset_release; mkdir "$GC_RELEASE_BACKUP_LOCKDIR";        refuse_case "nightly backup lock held" 0; rmdir "$GC_RELEASE_BACKUP_LOCKDIR"
  reset_release; mkdir "$CT/rel/.dolt-backup/hq.new";       refuse_case "reseed residue hq.new present" 0
  reset_release; _gc_release_writer_active() { return 0; }; refuse_case "a backup writer is running" 0
  reset_release; PROBE_RC=1;                                refuse_case "Dolt not confirmed healthy" 0
  # A probe that never LOADED is "cannot tell", not "healthy" — deleting backup data fails closed on it.
  reset_release; unset -f gc_dolt_probe;                    refuse_case "the Dolt health probe is not loaded (cannot tell = not healthy)" 0
  grep -q 'health probe is not loaded' "$DOLT_GC_MAINT_LOG" && ok "refuse: a missing probe is logged as such (not confused with an unhealthy Dolt)" || bad "refuse: missing probe not named in the log"
  gc_dolt_probe() { return "$PROBE_RC"; }
  reset_release; PROOF_RC=1;                                refuse_case "S3 is NOT proven identical+restorable (proof returns 1)" 1
  reset_release; unset -f _s3proof_repair_then_prove;       refuse_case "the S3 proof library is not loaded" 0
  # The refusal itself would happen anyway (an undefined function is command-not-found → non-zero);
  # the explicit veto exists so the LOG says why. Pin that, so the reason cannot silently regress
  # into a confusing "S3 is not proven" line (or a bare "command not found" on stderr).
  grep -q 'S3 proof library is not loaded' "$DOLT_GC_MAINT_LOG" && ok "refuse: a missing proof lib is logged as such (operator sees WHY, not a generic proof failure)" || bad "refuse: missing proof lib not named in the log"
  _s3proof_repair_then_prove() { PROOF_CALLS=$((PROOF_CALLS+1)); [ -n "$PROOF_SIDE" ] && eval "$PROOF_SIDE"; return "$PROOF_RC"; }
  reset_release; rm -rf "$CT/rel/.dolt-backup/hq"
  if ! MAYBE && [ "$PROOF_CALLS" -eq 0 ]; then ok "refuse: no local staging at all → nothing to release, proof never run"; else bad "refuse: absent staging reached the proof"; fi
  reset_release; rm -rf "$CT/rel/.dolt-backup/hq"; mkdir -p "$CT/rel/.dolt-backup/hq"
  if ! MAYBE && [ -d "$(STAGE_DIR)" ] && [ "$PROOF_CALLS" -eq 0 ]; then ok "refuse: an EMPTY hq dir (no manifest) is not a backup copy → untouched, proof never run"; else bad "refuse: empty hq dir was treated as releasable"; fi

  # The proof can take minutes; state that moved DURING it must veto the delete.
  reset_release; PROOF_SIDE='printf "6:__DOLT__:lock:CHANGED:gcgen\n" > "$(STAGE_DIR)/manifest"'
  refuse_case "the staging manifest CHANGED while proving S3 (a writer touched it)" 1
  reset_release; PROOF_SIDE='mkdir "$CT/rel/.dolt-backup/hq.new"'
  refuse_case "reseed residue APPEARED while proving S3" 1
  reset_release; PROOF_SIDE='mkdir "$GC_RELEASE_BACKUP_LOCKDIR"'
  refuse_case "the nightly backup lock was taken while proving S3" 1
  reset_release; PROOF_SIDE=""

  # DRYRUN decides + proves but must not delete, notify or stamp the cooldown.
  reset_release; GC_RELEASE_STAGING_DRYRUN=1
  if ! MAYBE && [ -d "$(STAGE_DIR)" ] && [ "$PROOF_CALLS" -eq 1 ] && [ ! -e "$GC_RELEASE_STATE" ] && [ "$NOTIFY_N" -eq 0 ]; then
    ok "dryrun: proves S3, logs WOULD RELEASE, deletes nothing, no cooldown stamp, no notification"
  else bad "dryrun: staging_exists=$([ -d "$(STAGE_DIR)" ] && echo y || echo N) calls=$PROOF_CALLS state=$([ -e "$GC_RELEASE_STATE" ] && echo y || echo n) notify=$NOTIFY_N"; fi
  grep -q 'DRYRUN — WOULD RELEASE' "$DOLT_GC_MAINT_LOG" && ok "dryrun: the WOULD RELEASE line is in the log" || bad "dryrun: no WOULD RELEASE log line"

  # The delete must be confined to hq: a sibling database staging survives a release.
  reset_release; mkstage "$CT/rel/.dolt-backup" whatsapp_automation
  MAYBE
  if [ ! -e "$(STAGE_DIR)" ] && [ -s "$CT/rel/.dolt-backup/whatsapp_automation/manifest" ]; then ok "release: a sibling db's staging (whatsapp_automation) is untouched — the delete is confined to hq"; else bad "release: sibling staging was affected"; fi

  # mutation guard: if the proof gate were skipped the 'proof fails' scenario would delete —
  # prove the test above can actually fail by running it against a proof that lies "0".
  reset_release; PROOF_RC=0
  MAYBE
  [ ! -e "$(STAGE_DIR)" ] && ok "mutation-check: with a proof that says 0 the SAME scenario deletes — so the 'proof=1 → intact' assertion is a real discriminator" || bad "mutation-check: proof=0 did not delete; the refuse test proves nothing"

  unset -f du gc_dolt_probe _s3proof_repair_then_prove _gc_release_writer_active mkstage reset_release STAGE_DIR MAYBE refuse_case
  unset -f _dolt_gc_notify _dolt_gc_mail_mayor
  # only ever remove the mktemp dir this block created
  case "$CT" in "${TMPDIR:-/tmp}"/dolt-gc-release-selftest.*) rm -rf "$CT" ;; esac
fi

# ═══ ga-mb57np: what the headroom-poll trigger (dolt-gc-release-trigger.sh) relies on ═══
# The trigger starts THIS job outside the 2h cadence, so three properties matter here:
#   1. one place computes the gate's `required` (the trigger must not carry its own copy);
#   2. two runs can never overlap (launchd only serializes its OWN label — a manual run or the
#      trigger's child is invisible to it), and a crashed run's lock must not wedge the job;
#   3. a triggered run does only the size-gated GC step, and its skips are not 2h "cycles".

# ── _gc_required_parts: the one place `required` is computed ─────────────────────────────
r="$(_gc_required_parts 8247 200 3072)"; [ "$r" = "16494 11319 16494" ] && ok "required: hq 8247MB @200% → pct=16494 floor=11319 required=16494 (max of the two)" || bad "required big-hq got: '$r'"
r="$(_gc_required_parts 1000 200 3072)"; [ "$r" = "2000 4072 4072" ] && ok "required: a small hq is governed by the absolute floor (size+3072), not the percentage" || bad "required small-hq got: '$r'"
r="$(_gc_required_parts 8247 280 3072)"; [ "$r" = "23091 11319 23091" ] && ok "required: the with-prune percentage (280) flows through" || bad "required prune got: '$r'"
for _bad in "" "abc" "-1" "1.5"; do
  r="$(_gc_required_parts "$_bad" 200 3072)"; _gc_required_parts "$_bad" 200 3072 >/dev/null 2>&1; rc=$?
  if [ -z "$r" ] && [ "$rc" -ne 0 ]; then ok "required: unmeasurable size '$_bad' → nothing printed, rc!=0 (never a fabricated number)"; else bad "required: size '$_bad' gave out='$r' rc=$rc"; fi
done
r="$(_gc_required_parts 8247 "" 3072)"; _gc_required_parts 8247 "" 3072 >/dev/null 2>&1; rc=$?
if [ -z "$r" ] && [ "$rc" -ne 0 ]; then ok "required: blank pct → nothing printed, rc!=0"; else bad "required blank pct got: out='$r' rc=$rc"; fi
r="$(_gc_required_parts 8247 200 "")"; _gc_required_parts 8247 200 "" >/dev/null 2>&1; rc=$?
if [ -z "$r" ] && [ "$rc" -ne 0 ]; then ok "required: blank floor → nothing printed, rc!=0"; else bad "required blank floor got: out='$r' rc=$rc"; fi
unset _bad rc

# ── single-instance lock (real filesystem, real processes) ──────────────────────────────
LT="$(mktemp -d "${TMPDIR:-/tmp}/dolt-gc-lock-selftest.XXXXXX")"
if [ -z "$LT" ] || [ ! -d "$LT" ]; then bad "lock: mktemp failed — lock tests skipped"; else
  LD="$LT/run.lock.d"; RE="selftest"        # this very process is the live holder (its command line has 'selftest')
  _dgm_lock_acquire "$LD" "$RE"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$LD/pid" 2>/dev/null)" = "$$" ] && ok "lock: a free lock is acquired and stamped with our pid" || bad "lock acquire rc=$rc pid='$(cat "$LD/pid" 2>/dev/null)'"
  _dgm_lock_acquire "$LD" "$RE"; rc=$?
  [ "$rc" -eq 1 ] && ok "lock: a second acquire while the holder is alive → 1 (held) — two runs never overlap" || bad "lock second acquire rc=$rc (want 1)"
  _dgm_lock_release "$LD"
  [ ! -e "$LD" ] && ok "lock: release by the owner removes the lock" || bad "lock not released"
  _dgm_lock_acquire "$LD" "$RE" && ok "lock: re-acquirable after a release" || bad "lock not re-acquirable"
  _dgm_lock_release "$LD"

  # stale: holder died (crash / SIGKILL) → next run reclaims instead of wedging the job forever
  mkdir "$LD"; sleep 0 & _dead=$!; wait "$_dead" 2>/dev/null; printf '%s\n' "$_dead" > "$LD/pid"
  _dgm_lock_acquire "$LD" "$RE"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$LD/pid" 2>/dev/null)" = "$$" ] && ok "lock: a dead holder's lock is reclaimed (a crashed run cannot wedge the job)" || bad "stale lock not reclaimed rc=$rc pid='$(cat "$LD/pid" 2>/dev/null)'"
  _dgm_lock_release "$LD"

  # pid reuse: the recorded pid is ALIVE but is some other program → not our holder → stale
  mkdir "$LD"; sleep 30 & _other=$!; printf '%s\n' "$_other" > "$LD/pid"
  _dgm_lock_acquire "$LD" "dolt-gc-maintenance-only-this-name"; rc=$?
  [ "$rc" -eq 0 ] && ok "lock: recorded pid alive but running something else (pid reuse) → treated as stale and reclaimed" || bad "pid-reuse lock not reclaimed rc=$rc"
  _dgm_lock_release "$LD"
  mkdir "$LD"; printf '%s\n' "$_other" > "$LD/pid"
  _dgm_lock_acquire "$LD" "sleep"; rc=$?
  [ "$rc" -eq 1 ] && ok "lock: the same live pid WITH a matching command is a real holder → held" || bad "matching live holder not honored rc=$rc"
  kill "$_other" 2>/dev/null; wait "$_other" 2>/dev/null; rmdir "$LD" 2>/dev/null; rm -f "$LD/pid"; rmdir "$LD" 2>/dev/null

  # no readable pid: fresh = the holder is between mkdir and writing its pid (held); old = crash leftover (stale)
  mkdir "$LD"
  _dgm_lock_acquire "$LD" "$RE"; rc=$?
  [ "$rc" -eq 1 ] && ok "lock: a FRESH lock dir with no pid yet → held (its creator is mid-acquire)" || bad "fresh pid-less lock rc=$rc (want 1)"
  touch -t 202001010000 "$LD"
  _dgm_lock_acquire "$LD" "$RE"; rc=$?
  [ "$rc" -eq 0 ] && ok "lock: an OLD pid-less lock dir (crash between mkdir and pid write) → reclaimed" || bad "old pid-less lock rc=$rc (want 0)"
  _dgm_lock_release "$LD"
  mkdir "$LD"; printf 'garbage\n' > "$LD/pid"; touch -t 202001010000 "$LD"
  _dgm_lock_acquire "$LD" "$RE"; rc=$?
  [ "$rc" -eq 0 ] && ok "lock: an old lock whose pid file is garbage → reclaimed" || bad "garbage-pid lock rc=$rc"
  _dgm_lock_release "$LD"

  # release only by the owner
  mkdir "$LD"; printf '%s\n' 99999999 > "$LD/pid"
  _dgm_lock_release "$LD"
  [ -d "$LD" ] && ok "lock: release by a NON-owner leaves the lock alone" || bad "non-owner release removed someone else's lock"
  rm -f "$LD/pid"; rmdir "$LD" 2>/dev/null

  # a lock dir that cannot be created is a third state (2), not 'held' and not 'acquired'
  printf 'x' > "$LT/afile"
  _dgm_lock_acquire "$LT/afile/child.lock.d" "$RE"; rc=$?
  [ "$rc" -eq 2 ] && ok "lock: an uncreatable lock dir → 2 (cannot lock) — distinct from held(1) and acquired(0)" || bad "uncreatable lock rc=$rc (want 2)"

  # _dgm_lock_held (read-only; what the trigger asks)
  _dgm_lock_held "$LT/nothing.lock.d" "$RE" && bad "held: an absent lock must not read as held" || ok "held: no lock dir → not held"
  mkdir "$LD"; printf '%s\n' "$$" > "$LD/pid"
  _dgm_lock_held "$LD" "$RE" && ok "held: live matching holder → held" || bad "held: live holder not seen"
  _dgm_lock_held "$LD" "no-such-command-name" && bad "held: live pid with a non-matching command must not read as held" || ok "held: live pid, different program (reuse) → not held"
  rm -f "$LD/pid"; rmdir "$LD" 2>/dev/null
  case "$LT" in "${TMPDIR:-/tmp}"/dolt-gc-lock-selftest.*) rm -rf "$LT" ;; esac
fi

# ── triggered run: main() runs ONLY the size-gated GC; skips are not 2h cycles ───────────
XT="$(mktemp -d "${TMPDIR:-/tmp}/dolt-gc-triggered-selftest.XXXXXX")"
if [ -z "$XT" ] || [ ! -d "$XT" ]; then bad "triggered: mktemp failed — tests skipped"; else
  BD_LOG="$XT/bd.calls"; : > "$BD_LOG"
  printf '#!/bin/sh\necho "$@" >> "%s"\nexit 0\n' "$BD_LOG" > "$XT/bd-stub"; chmod +x "$XT/bd-stub"
  BD="$XT/bd-stub"
  LOG="$XT/x.log"; DOLT_GC_MAINT_LOG="$LOG"
  GC_SKIP_STREAK_STATE="$XT/streak.state"
  DOLTDIR="$XT/hq"; mkdir -p "$DOLTDIR"; DB="hq"; PORT=1; THRESHOLD_G=1
  PRUNE_ENABLED=0; FLATTEN_ENABLED=0
  GC_MIN_FREE_PCT=200; GC_MIN_FREE_ABS_MB=3072; GC_MIN_FREE_PCT_BASE=200; GC_MIN_FREE_PCT_WITH_PRUNE=280
  FAKE_HQ_MB=8247; FAKE_AVAIL=3000; DOLT_CALLS=0; RELEASE_CALLS=0; NOTIFY_N=0; MAIL_N=0
  du() { case "${1:-}" in -sm) printf '%s\t%s\n' "$FAKE_HQ_MB" "${2:-}" ;; -sh) printf '%sM\t%s\n' "$FAKE_HQ_MB" "${2:-}" ;; *) command du "$@" ;; esac; }
  _avail_mb() { printf '%s' "$FAKE_AVAIL"; }
  timeout() { shift; "$@"; }
  dolt() { DOLT_CALLS=$((DOLT_CALLS+1)); FAKE_HQ_MB=4000; return 0; }
  _gc_maybe_release_staging() { RELEASE_CALLS=$((RELEASE_CALLS+1)); return 1; }
  _dolt_gc_notify() { NOTIFY_N=$((NOTIFY_N+1)); }
  _dolt_gc_mail_mayor() { MAIL_N=$((MAIL_N+1)); }
  xreset() { : > "$BD_LOG"; : > "$LOG"; printf '62 1\n' > "$GC_SKIP_STREAK_STATE"; FAKE_HQ_MB=8247; FAKE_AVAIL=3000; DOLT_CALLS=0; RELEASE_CALLS=0; NOTIFY_N=0; MAIL_N=0; unset GC_TRIGGERED_RUN; }

  # a NORMAL 2h cycle that skips advances the streak (unchanged behavior) and still tries the release
  xreset; main
  [ "$(_read_skip_streak "$GC_SKIP_STREAK_STATE")" = "63 1" ] && ok "cycle: a normal 2h run that skips advances the streak 62→63" || bad "cycle streak got '$(_read_skip_streak "$GC_SKIP_STREAK_STATE")'"
  [ "$RELEASE_CALLS" -eq 1 ] && [ "$DOLT_CALLS" -eq 0 ] && ok "cycle: the skip still consults the staging release, and dolt_gc is not called" || bad "cycle skip flow: release=$RELEASE_CALLS dolt=$DOLT_CALLS"
  grep -q 'purge' "$BD_LOG" && ok "cycle: a normal run still does the ephemeral purge (step 1 untouched)" || bad "cycle: the purge did not run"

  # a TRIGGERED run that skips does NOT advance the streak, does the GC-only path, still consults the release
  xreset; GC_TRIGGERED_RUN=1 main
  [ "$(_read_skip_streak "$GC_SKIP_STREAK_STATE")" = "62 1" ] && ok "triggered: a skip does NOT advance the 2h-cycle streak (62 stays 62)" || bad "triggered streak got '$(_read_skip_streak "$GC_SKIP_STREAK_STATE")'"
  [ "$RELEASE_CALLS" -eq 1 ] && ok "triggered: a skip still goes through the (unchanged) guarded staging release" || bad "triggered: release not consulted ($RELEASE_CALLS)"
  [ ! -s "$BD_LOG" ] && ok "triggered: purge/prune/flatten are NOT run at poll cadence (bd never called)" || bad "triggered: bd was called: $(cat "$BD_LOG")"
  grep -q 'triggered run' "$LOG" && ok "triggered: the log says it was a triggered run" || bad "triggered: no log marker"

  # a triggered run whose gate PASSES runs dolt_gc and clears the streak
  xreset; FAKE_AVAIL=20000; GC_TRIGGERED_RUN=1 main
  [ "$DOLT_CALLS" -eq 1 ] && [ "$(_read_skip_streak "$GC_SKIP_STREAK_STATE")" = "0 0" ] && ok "triggered: gate passes → dolt_gc runs once and the skip streak is cleared" || bad "triggered pass: dolt=$DOLT_CALLS streak='$(_read_skip_streak "$GC_SKIP_STREAK_STATE")'"
  grep -q 'dolt_gc OK' "$LOG" && ok "triggered: the run logs 'dolt_gc OK — hq X -> Y' (acceptance item 2)" || bad "triggered: no dolt_gc OK line"
  # a triggered run does not lower the gate: 1MB under → skip
  xreset; FAKE_AVAIL=16493; GC_TRIGGERED_RUN=1 main
  [ "$DOLT_CALLS" -eq 0 ] && ok "triggered: 1MB under the SAME gate → no dolt_gc (the gate is not loosened for triggered runs)" || bad "triggered: ran dolt_gc under the gate"
  xreset; FAKE_AVAIL=16494; GC_TRIGGERED_RUN=1 main
  [ "$DOLT_CALLS" -eq 1 ] && ok "triggered: exactly at the gate → dolt_gc runs (boundary matches a normal cycle)" || bad "triggered: not at gate boundary"
  # only the literal 1 selects triggered mode
  xreset; GC_TRIGGERED_RUN=0 main
  [ "$(_read_skip_streak "$GC_SKIP_STREAK_STATE")" = "63 1" ] && grep -q purge "$BD_LOG" && ok "triggered: GC_TRIGGERED_RUN=0 is a normal cycle" || bad "GC_TRIGGERED_RUN=0 treated as triggered"
  xreset; GC_TRIGGERED_RUN=yes main
  [ "$(_read_skip_streak "$GC_SKIP_STREAK_STATE")" = "63 1" ] && ok "triggered: any value other than the literal 1 is a normal cycle" || bad "GC_TRIGGERED_RUN=yes treated as triggered"

  unset -f du _avail_mb timeout dolt _gc_maybe_release_staging _dolt_gc_notify _dolt_gc_mail_mayor xreset
  unset GC_TRIGGERED_RUN
  case "$XT" in "${TMPDIR:-/tmp}"/dolt-gc-triggered-selftest.*) rm -rf "$XT" ;; esac
fi

# ── static: the lock wraps the real entry point, and only there ────────────────────────
grep -Eq '_dgm_lock_acquire "\$GC_MAINT_LOCKDIR"' "$SCRIPT" && ok "static: the non-library entry point takes the single-instance lock" || bad "static: main is not wrapped by the lock"
/bin/bash -n "$SCRIPT" 2>/dev/null && ok "static: parses under /bin/bash (3.2) — the interpreter launchd runs it with" || bad "static: does not parse under /bin/bash 3.2"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
