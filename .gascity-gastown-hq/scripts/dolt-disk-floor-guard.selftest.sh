#!/bin/bash
# dolt-disk-floor-guard.selftest.sh — unit tests for the PURE decision logic of
# dolt-disk-floor-guard.sh: avail-GB df-parsing, floor classification, worsening
# detection, and cooldown + worsening-bypass notify gating.
#
# Hermetic: sources the script as a LIBRARY (DOLT_DISK_FLOOR_GUARD_LIB=1) so main()
# never runs, points the log at a throwaway path. Never calls `gc dolt-cleanup`,
# `gc mail send`, `notify`, or the real scratchpad-reaper.sh; nothing is deleted,
# nothing is sent, nothing in Dolt's data dir or /private/tmp is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dolt-disk-floor-guard.sh"

export DOLT_DISK_FLOOR_GUARD_LIB=1
export DOLT_DISK_FLOOR_GUARD_LOG="/tmp/dolt-disk-floor-guard-selftest-$$.log"
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-disk-floor-guard.selftest.sh ==="

# ── _avail_gb: real df parsing (NOT stubbed — proves the -k/1024/1024 math matches
#    this machine's actual df output format; the decision-function tests below
#    stub avail directly and don't depend on this) ────────────────────────────────
g="$(_avail_gb /tmp)"
case "$g" in
  ''|*[!0-9]*) bad "_avail_gb(/tmp) did not return an integer (got: '$g')" ;;
  *) [ "$g" -gt 0 ] && ok "_avail_gb(/tmp) returns a positive integer GB ($g)" || bad "_avail_gb(/tmp) returned non-positive: $g" ;;
esac

# ── _avail_gb: nonexistent path → "" (surfaces as UNKNOWN, never a silent 0 —
#    ga-p5q3: error and empty must not collapse to the same value as "fine") ──────
g="$(_avail_gb "/nonexistent/path/$$/does-not-exist")"
[ "$g" = "" ] && ok "_avail_gb(nonexistent path) → '' (df failure surfaces, not masked)" || bad "_avail_gb(nonexistent) got: '$g' (expected empty)"

# ── _floor_class: NONE / WARN / CRITICAL / UNKNOWN boundaries (warn=8 crit=3) ─────
[ "$(_floor_class 20 8 3)" = "NONE" ]      && ok "class: 20GB avail, floors(8,3) → NONE"                    || bad "class 20/8/3 wrong: $(_floor_class 20 8 3)"
[ "$(_floor_class 8  8 3)" = "WARN" ]      && ok "class: avail==warn floor → WARN (boundary inclusive)"     || bad "class 8/8/3 wrong: $(_floor_class 8 8 3)"
[ "$(_floor_class 5  8 3)" = "WARN" ]      && ok "class: between crit and warn → WARN"                      || bad "class 5/8/3 wrong: $(_floor_class 5 8 3)"
[ "$(_floor_class 3  8 3)" = "CRITICAL" ]  && ok "class: avail==crit floor → CRITICAL (boundary inclusive)" || bad "class 3/8/3 wrong: $(_floor_class 3 8 3)"
[ "$(_floor_class 0  8 3)" = "CRITICAL" ]  && ok "class: avail=0 → CRITICAL"                                || bad "class 0/8/3 wrong: $(_floor_class 0 8 3)"
[ "$(_floor_class ""  8 3)" = "UNKNOWN" ]  && ok "class: empty avail (df failed) → UNKNOWN, never NONE"     || bad "class empty wrong: $(_floor_class "" 8 3)"
[ "$(_floor_class abc 8 3)" = "UNKNOWN" ]  && ok "class: non-numeric avail → UNKNOWN"                       || bad "class abc wrong: $(_floor_class abc 8 3)"

# ── _worsening: avail-GB FALLING = worsening (inverse framing of
#    disk-pressure-monitor's usage-% rising; same idiom) ─────────────────────────
_worsening 5 8  && ok "worsening: 5GB < last-notified 8GB → true (pressure increased)"              || bad "worsening 5<8 should be true"
_worsening 8 5  && bad "worsening: 8GB > last-notified 5GB should be FALSE (avail improved)"         || ok "worsening: improved avail → false"
_worsening 5 5  && bad "worsening: unchanged avail should be FALSE (no new info)"                    || ok "worsening: unchanged avail → false"
_worsening 5 "" && bad "worsening: no prior value should be FALSE (unknown trend isn't a bypass)"    || ok "worsening: no prior notified value → false"

# ── _cooldown_elapsed: fail-open on no/invalid prior timestamp ───────────────────
_cooldown_elapsed "" 1000 3600   && ok "cooldown: no prior timestamp → elapsed (fail-open)"        || bad "cooldown empty should fail-open"
_cooldown_elapsed 1000 1000 3600 && bad "cooldown: 0s elapsed should NOT be elapsed"                 || ok "cooldown: just-notified → still cooling down"
_cooldown_elapsed 1000 4601 3600 && ok "cooldown: 3601s elapsed >= 3600s window → elapsed"          || bad "cooldown: should have elapsed"
_cooldown_elapsed 1000 4600 3600 && ok "cooldown: exactly 3600s elapsed → elapsed (boundary >=)"    || bad "cooldown: boundary should be inclusive"

# ── _should_notify: composed gate — cooldown-elapsed OR worsening (ga-vs55 furo #2
#    lesson: a cooldown blind to trend silenced a real emergency 28min before Dolt
#    died; this MUST NOT regress that fix onto the new guard) ────────────────────
_should_notify 1000 1100 3600 5 8  && ok "should_notify: within cooldown BUT worsening (5<8) → notify anyway"      || bad "should_notify: worsening should bypass cooldown"
_should_notify 1000 1100 3600 8 5  && bad "should_notify: within cooldown, improved, no bypass → should suppress" || ok "should_notify: within cooldown + improved avail → suppressed"
_should_notify 1000 4601 3600 8 8  && ok "should_notify: cooldown elapsed, stable avail → notify (repeat allowed)" || bad "should_notify: elapsed cooldown should notify regardless of trend"
_should_notify "" 1100 3600 8 ""   && ok "should_notify: never notified before → notify (fail-open)"               || bad "should_notify: first-ever call should notify"

echo ""
echo "=== _reap_dead_scratch: production sentinel wiring (ga-h565g) ==="
# _reap_dead_scratch is the REAL caller scratchpad-reaper.sh's own header
# names as the one allowed to set SCRATCHPAD_REAPER_PROD=1 (ga-h565g) — this
# proves it actually does, BEFORE _reap_dead_scratch gets stubbed out below
# for the main() scenarios. Hermetic: CITY is a plain global (not readonly),
# reassigned here to a disposable tmp dir containing a FAKE
# scratchpad-reaper.sh that only records what env it received — never touches
# the real scratchpad-reaper.sh, no real `gc session list`, no real deletion.
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/scratchpad-reaper.sh" <<EOF
#!/bin/bash
echo "PROD=\${SCRATCHPAD_REAPER_PROD:-unset}" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/scratchpad-reaper.sh"

REAL_CITY="$CITY"
CITY="$FAKE_CITY"
_reap_dead_scratch
CITY="$REAL_CITY"

if [ -f "$CAPTURE_FILE" ] && grep -qx "PROD=1" "$CAPTURE_FILE"; then
  ok "_reap_dead_scratch: sets SCRATCHPAD_REAPER_PROD=1 when invoking the real reaper (production opt-in wired)"
else
  bad "_reap_dead_scratch: did NOT set SCRATCHPAD_REAPER_PROD=1 — real launchd path would silently dry-run forever (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== main(): CRITICAL-latch across reclaim reclassification (gate-fix-1: GATE-FEEDBACK gate_run=ga-wisp-9b4hnh) ==="
# The pure-function tests above prove _should_notify is correct in ISOLATION.
# They do NOT exercise main() itself, which is where the actual bug lived:
# main() re-derives `class` from the POST-reclaim avail and (pre-fix) used
# that alone to decide the CRITICAL-only "always notify, mail Mayor" path —
# so a reclaim that recovered avail lost all memory that the cycle was ever
# CRITICAL. These tests call main() directly (still library-sourced, so it
# doesn't auto-run) with _avail_gb/_safe_reclaim/_reap_dead_scratch/NOTIFY/GC
# stubbed — no real df dependency, no real reclaim, no real scratchpad reap, no
# real notification or mail sent, and the state files are redirected to a
# throwaway tmp dir (never touches the real .gc/logs state).

STATE_TMP="/tmp/dolt-disk-floor-guard-selftest-state-$$"
mkdir -p "$STATE_TMP"
# shellcheck disable=SC2034  # read by _write_state() in the sourced script
STATE_DIR="$STATE_TMP"
STATE_EPOCH_FILE="$STATE_TMP/.last-notify"
STATE_AVAIL_FILE="$STATE_TMP/.last-notify-avail-gb"

# Canned avail-GB readings: main() calls _avail_gb exactly twice per cycle
# (pre-reclaim, then post-reclaim), both via `$(...)` command substitution —
# which forks a SUBSHELL, so a shell-variable/array queue popped inside
# _avail_gb would silently discard its own mutation on subshell exit (every
# call would keep re-reading the same first element). A FILE-backed queue
# survives across subshells since the pop is a real filesystem write, not
# in-memory shell state. Exhausting the queue returns "" (UNKNOWN) rather
# than erroring under `set -u`, so an unexpected extra call fails the
# assertion instead of aborting the whole selftest.
AVAIL_QUEUE_FILE="$STATE_TMP/.avail-queue"
queue_avail() { printf '%s\n' "$@" > "$AVAIL_QUEUE_FILE"; }
_avail_gb() {
  [ -s "$AVAIL_QUEUE_FILE" ] || { echo ""; return; }
  local v; v="$(head -n1 "$AVAIL_QUEUE_FILE")"
  tail -n +2 "$AVAIL_QUEUE_FILE" > "$AVAIL_QUEUE_FILE.tmp" 2>/dev/null || true
  mv "$AVAIL_QUEUE_FILE.tmp" "$AVAIL_QUEUE_FILE"
  echo "$v"
}
# _safe_reclaim's own mechanics (gc dolt-cleanup --force, health probe) are
# EXECUTION code out of scope for this file (see section banner above) —
# stubbed as a no-op here too, same as every other main()-only side effect.
_safe_reclaim() { :; }

# _reap_dead_scratch is new (ga-02pnu): stubbed as a no-op for the SAME reason
# _safe_reclaim is — it's EXECUTION code (shells out to scratchpad-reaper.sh,
# which has its own independent selftest). REAP_CALLS proves main() actually
# invokes it as part of the reclaim step (integration wiring), without ever
# running the real reaper (no `gc session list`, no `rm -rf`, hermetic).
REAP_CALLS=0
_reap_dead_scratch() { REAP_CALLS=$((REAP_CALLS+1)); }

NOTIFY_CALLS=0; NOTIFY_LAST_PRIO=""
record_notify() {
  NOTIFY_CALLS=$((NOTIFY_CALLS+1))
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) NOTIFY_LAST_PRIO="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}
# shellcheck disable=SC2034  # read by main() in the sourced script
NOTIFY=record_notify

GC_MAIL_CALLS=0
record_gc() {
  [ "$1" = "mail" ] && [ "$2" = "send" ] && GC_MAIL_CALLS=$((GC_MAIL_CALLS+1))
}
# shellcheck disable=SC2034  # read by main() in the sourced script
GC=record_gc

reset_capture() { NOTIFY_CALLS=0; NOTIFY_LAST_PRIO=""; GC_MAIL_CALLS=0; REAP_CALLS=0; }
seed_state() {
  if [ -n "$1" ]; then echo "$1" > "$STATE_EPOCH_FILE"; else rm -f "$STATE_EPOCH_FILE"; fi
  if [ -n "$2" ]; then echo "$2" > "$STATE_AVAIL_FILE"; else rm -f "$STATE_AVAIL_FILE"; fi
}

# Scenario A — repro path (a) from the GATE-FEEDBACK: CRITICAL (2GB) fully
# recovers to NONE (20GB) after reclaim. Pre-fix, main() hit the early return
# "back above floor after reclaim — no notify needed" and NEITHER notify nor
# mail-Mayor ever fired for a reading that was CRITICAL moments earlier.
reset_capture; seed_state "" ""
queue_avail 2 20
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "5" ] && [ "$GC_MAIL_CALLS" = "1" ]; then
  ok "main(): CRITICAL avail fully recovered by reclaim still notifies (prio 5) + mails Mayor"
else
  bad "main(): CRITICAL->NONE recovery lost the notify/mail (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO mail_calls=$GC_MAIL_CALLS)"
fi

# Scenario B — repro path (b), reviewer's exact numbers (WARN=8 CRIT=3
# cooldown=3600): CRITICAL (2GB) reclaims back to EXACTLY the WARN floor
# (8GB), within cooldown and not "worsening" vs. a last-notified avail of
# 8GB. Pre-fix, class was reclassified WARN post-reclaim and ordinary WARN
# cooldown/worsening suppression swallowed the CRITICAL-only mail-Mayor alert.
reset_capture
past_epoch=$(( $(date +%s) - 600 ))
seed_state "$past_epoch" 8
queue_avail 2 8
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "5" ] && [ "$GC_MAIL_CALLS" = "1" ]; then
  ok "main(): CRITICAL avail partially recovered into WARN tier still bypasses cooldown + mails Mayor"
else
  bad "main(): CRITICAL->WARN partial recovery lost the always-notify/mail-Mayor guarantee (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO mail_calls=$GC_MAIL_CALLS)"
fi

# Scenario C — non-regression: a cycle that is NEVER critical (WARN both
# before and after reclaim) still respects ordinary cooldown + not-worsening
# suppression — proves the was_critical latch didn't make the guard noisier.
reset_capture
past_epoch=$(( $(date +%s) - 100 ))
seed_state "$past_epoch" 6
queue_avail 6 6
main
if [ "$NOTIFY_CALLS" = "0" ] && [ "$GC_MAIL_CALLS" = "0" ]; then
  ok "main(): non-critical WARN cycle within cooldown + not worsening still suppresses (no regression)"
else
  bad "main(): non-critical WARN suppression regressed (notify_calls=$NOTIFY_CALLS mail_calls=$GC_MAIL_CALLS)"
fi

# Scenario D — non-regression: a non-critical WARN cycle fully resolved by
# reclaim takes the early-return silent path, same as before the fix.
reset_capture; seed_state "" ""
queue_avail 6 20
main
if [ "$NOTIFY_CALLS" = "0" ] && [ "$GC_MAIL_CALLS" = "0" ]; then
  ok "main(): non-critical WARN fully resolved by reclaim stays silent (no regression)"
else
  bad "main(): non-critical WARN->NONE early-return regressed (notify_calls=$NOTIFY_CALLS mail_calls=$GC_MAIL_CALLS)"
fi

echo ""
echo "=== main(): scratchpad-reap integration (ga-02pnu) ==="
# Scenario E — the new reclaim lever must actually be wired into main()'s
# reclaim step (called alongside _safe_reclaim, before the post-reclaim avail
# re-read) on EVERY cycle that reaches the reclaim step at all — regardless of
# whether the outcome ends up CRITICAL, WARN-notify, or WARN-suppressed. Reuses
# scenario A's readings (CRITICAL -> recovers to NONE).
reset_capture; seed_state "" ""
queue_avail 2 20
main
[ "$REAP_CALLS" = "1" ] && ok "main(): _reap_dead_scratch invoked exactly once alongside _safe_reclaim" || bad "main(): expected _reap_dead_scratch called once, got REAP_CALLS=$REAP_CALLS"

# Scenario F — a cycle that never reaches the floor at all (avail comfortably
# above warn on the FIRST read) must take the top early-return and never touch
# either reclaim lever — proves the reap call didn't get hoisted above the
# floor check.
reset_capture; seed_state "" ""
queue_avail 20
main
[ "$REAP_CALLS" = "0" ] && ok "main(): avail above floor on first read never invokes _reap_dead_scratch" || bad "main(): expected zero reap calls when floor never breached, got REAP_CALLS=$REAP_CALLS"

rm -rf "$STATE_TMP"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
