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

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
