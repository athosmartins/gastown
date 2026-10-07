#!/usr/bin/env bash
# pilot-dispatcher.memory-tight.selftest.sh — ga-9e446u (part 1)
#
# The Pilot's cross-stage YIELD (ga-d0hz3) only counted Claude quota and Dolt CPU/latency as
# "resources tight". With Dolt calm and the machine on 8.2 GB of swap, the Gate (the higher stage)
# sat starved of RAM while the Pilot kept opening workers. _pilot_memory_tight is the third arm.
# This file is the DECISION MATRIX of that arm; the end-to-end "whole sweep yields / dispatches"
# scenarios (20d-mem-*) live in pilot-dispatcher.selftest.sh next to the ga-d0hz3 scenario they extend.
#
# Functions are extracted verbatim from the dispatcher (awk) and run in a child shell under the
# dispatcher's own `set -euo pipefail`, so an unguarded failing sysctl would abort the child and the
# scenario would FAIL (exactly how it would kill the real sweep). Run against a pre-fix dispatcher the
# functions do not exist and the file refuses to start — the honest red.
#
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

# fn_src <name> — the function's source verbatim, or nothing if the file does not define it.
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }

FUNCS="$(fn_src _pilot_swap_field)
$(fn_src _pilot_memory_tight)"
[ -n "$(fn_src _pilot_memory_tight)" ] || { echo "FATAL: _pilot_memory_tight() not found in $DISPATCHER (ga-9e446u not applied)" >&2; exit 2; }
[ -n "$(fn_src _pilot_swap_field)" ]   || { echo "FATAL: _pilot_swap_field() not found in $DISPATCHER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-memtight-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Fake sysctl — steered by files in $SELFTEST_WORK; with none present it fails like a missing binary.
cat > "$WORK/bin/sysctl" <<'SYSEOF'
#!/usr/bin/env bash
W="${SELFTEST_WORK:?}"
case "$*" in
  *vm.swapusage*)
    [ -f "$W/swapusage" ] || exit 1
    cat "$W/swapusage" ;;
  *kern.memorystatus_vm_pressure_level*)
    [ -f "$W/pressure" ] || exit 1
    cat "$W/pressure" ;;
  *) exit 1 ;;
esac
SYSEOF
chmod +x "$WORK/bin/sysctl"
# Fake df — the real one would answer for THIS machine's disk.
cat > "$WORK/bin/df" <<'DFEOF'
#!/usr/bin/env bash
W="${SELFTEST_WORK:?}"
[ -f "$W/diskfree" ] || exit 1
printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n/dev/disk3s5 237000 100000 %s 50%% /System/Volumes/Data\n' "$(cat "$W/diskfree")"
DFEOF
chmod +x "$WORK/bin/df"
sandbox_path_init "$WORK" || exit 2   # awk/sed/tr come from the system dirs; sysctl+df are the fakes above

reset() { rm -f "$WORK"/swapusage "$WORK"/pressure "$WORK"/diskfree; }

# run_mt — one _pilot_memory_tight call in a child shell; prints "<rc>|<reason>|<detail>".
# Inputs (all optional, via env): MT_ENABLED MT_USED_MAX MT_USED MT_FREE MT_DISK MT_PRESSURE
# (the *_OVERRIDE seams) — files in $WORK steer the fake sysctl/df for the real-probe path.
# The function is called BARE (not inside `if`/`||`/`&&`) on purpose: bash switches errexit OFF for
# the whole body of a function called in a conditional context, which would hide an unguarded
# failing sysctl. Bare, `set -e` is live in the body; "not tight" (rc 1) then ends the child, so the
# result is read from an EXIT trap. A body that aborts early leaves the detail EMPTY, and `expect`
# refuses an empty detail for an enabled run — an abort can never pass as "not tight".
run_mt() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    PILOT_MEMORY_TIGHT_ENABLED="${MT_ENABLED:-1}"
    PILOT_SWAP_USED_MAX_MB="${MT_USED_MAX:-7168}"
    PILOT_SWAP_FREE_FLOOR_MB=512
    PILOT_SWAP_GROW_DISK_MIN_MB=4096
    PILOT_SWAP_USED_OVERRIDE_MB="${MT_USED:-}"
    PILOT_SWAP_FREE_OVERRIDE_MB="${MT_FREE:-}"
    PILOT_DISK_FREE_OVERRIDE_MB="${MT_DISK:-}"
    PILOT_KERN_PRESSURE_OVERRIDE="${MT_PRESSURE:-}"
    PILOT_MEM_TIGHT_REASON="stale"; PILOT_MEM_TIGHT_DETAIL="stale"; PILOT_MEM_TIGHT_BLIND="stale"
    eval "$FUNCS"
    # MT_PRINT=blind prints ONLY the blind-readings list (ga-9e446u gate round 1, issue 3); the default
    # keeps the "<rc>|<reason>|<detail>" shape every expect() above parses.
    if [ "${MT_PRINT:-}" = blind ]; then
      trap 'printf "%s" "$PILOT_MEM_TIGHT_BLIND"' EXIT
    else
      trap 'printf "%s|%s|%s" "$?" "$PILOT_MEM_TIGHT_REASON" "$PILOT_MEM_TIGHT_DETAIL"' EXIT
    fi
    _pilot_memory_tight
    exit 0
  ) 2>&1
  return 0
}

# expect <label> <want_rc 0=tight|1=not> <want_reason> <got> [disabled]
expect() {
  local _label="$1" _wrc="$2" _wreason="$3" _got="$4" _mode="${5:-}" _grc _greason _gdetail
  _grc="${_got%%|*}"; _greason="${_got#*|}"; _greason="${_greason%%|*}"; _gdetail="${_got#*|*|}"
  if [ "$_mode" != "disabled" ] && [ -z "$_gdetail" ]; then
    bad "$_label — the function left no detail (aborted before finishing?): '$_got'"
  elif [ "$_grc" = "$_wrc" ] && [ "$_greason" = "$_wreason" ]; then
    ok "$_label"
  else
    bad "$_label — wanted rc=$_wrc reason='$_wreason', got '$_got'"
  fi
}

echo "pilot-dispatcher.memory-tight.selftest — the machine-memory arm of the cross-stage resource-tight predicate (ga-9e446u)"

echo "T1: swap USED above the ceiling → tight (the 8.2 GB incident)"
reset
expect "swap used 8400 MB → tight [swap-used]"      0 "swap-used" "$(MT_USED=8400 run_mt)"
expect "swap used 8400 MB, free swap OK (2000) → still tight (used alone is enough)" 0 "swap-used" "$(MT_USED=8400 MT_FREE=2000 run_mt)"

echo "T2: swap used at the measured healthy level, and at the boundary → NOT tight"
expect "swap used 4900 MB (measured healthy) → not tight" 1 "" "$(MT_USED=4900 run_mt)"
expect "swap used 7168 MB (exactly the ceiling) → not tight (strictly above)" 1 "" "$(MT_USED=7168 run_mt)"
expect "swap used 7169 MB → tight"                          0 "swap-used" "$(MT_USED=7169 run_mt)"
expect "swap used 0 → not tight"                           1 "" "$(MT_USED=0 run_mt)"
expect "ceiling is a knob: PILOT_SWAP_USED_MAX_MB=2000, used 2500 → tight" 0 "swap-used" "$(MT_USED_MAX=2000 MT_USED=2500 run_mt)"

echo "T3: kernel pressure — only level 4 counts (the gate's own rule, ga-q4fkxa)"
expect "pressure 4 (critical) → tight"                       0 "pressure-4" "$(MT_PRESSURE=4 run_mt)"
expect "pressure 2 (warn) alone → NOT tight"                 1 "" "$(MT_PRESSURE=2 run_mt)"
expect "pressure 1 (normal) → not tight"                     1 "" "$(MT_PRESSURE=1 run_mt)"
expect "pressure 3 (not a kernel level) → no signal, not tight" 1 "" "$(MT_PRESSURE=3 run_mt)"

echo "T4: free swap counts only when swap CANNOT grow (free < floor AND disk < grow-min)"
expect "free 100 MB + disk 2000 MB → tight [swap-exhausted]" 0 "swap-exhausted" "$(MT_FREE=100 MT_DISK=2000 run_mt)"
expect "free 100 MB + disk 100000 MB (swap can grow) → NOT tight" 1 "" "$(MT_FREE=100 MT_DISK=100000 run_mt)"
expect "free 100 MB + disk unreadable → no signal, not tight" 1 "" "$(MT_FREE=100 run_mt)"
expect "free 600 MB (above floor) + disk 2000 MB → not tight" 1 "" "$(MT_FREE=600 MT_DISK=2000 run_mt)"
expect "free 511 MB + disk 4095 MB (one under each line) → tight" 0 "swap-exhausted" "$(MT_FREE=511 MT_DISK=4095 run_mt)"
expect "free 512 MB (exactly the floor) → not tight" 1 "" "$(MT_FREE=512 MT_DISK=0 run_mt)"

echo "T5: several signals → all named, joined with +"
expect "pressure 4 + swap used 9000 → [pressure-4+swap-used]" 0 "pressure-4+swap-used" "$(MT_PRESSURE=4 MT_USED=9000 run_mt)"
expect "all three → [pressure-4+swap-used+swap-exhausted]"    0 "pressure-4+swap-used+swap-exhausted" "$(MT_PRESSURE=4 MT_USED=9000 MT_FREE=10 MT_DISK=100 run_mt)"

echo "T6: unreadable / garbage readings are NO signal — fail-OPEN, and never abort the sweep (set -e)"
reset
expect "no overrides, sysctl+df fail → not tight, child survives set -euo pipefail" 1 "" "$(run_mt)"
expect "garbage values (abc / -5 / 3) → not tight" 1 "" "$(MT_USED=abc MT_FREE=-5 MT_PRESSURE=3 MT_DISK=xyz run_mt)"
R="$(run_mt)"
case "$R" in
  *"swap_used=?MB"*"swap_free=?MB"*"pressure=?"*) ok "the detail says '?' for every reading it could not take — blind is not 'zero'" ;;
  *) bad "the detail does not mark the blind readings with '?': $R" ;;
esac

echo "T6b: a blind probe is NOT silent — PILOT_MEM_TIGHT_BLIND names every reading that could not be taken (ga-9e446u gate round 1)"
# Round 1 found the failure mode: fail-open is right, but "no reading" and "reading says fine" produced the
# same log (nothing), so a macOS update that changed the sysctl format would have turned the whole arm into a
# no-op with no trace. The list is what the caller logs; empty means every reading was taken.
reset
blind() { MT_PRINT=blind run_mt; }
eq_blind() { local _l="$1" _w="$2" _g="$3"; if [ "$_g" = "$_w" ]; then ok "$_l"; else bad "$_l — wanted '$_w', got '$_g'"; fi; }
eq_blind "no overrides, sysctl+df fail → all three readings named blind"      "swap_used,swap_free,pressure" "$(blind)"
eq_blind "used+pressure given, free missing → only swap_free is named"         "swap_free"                    "$(MT_USED=4900 MT_PRESSURE=1 blind)"
eq_blind "free+pressure given, used missing → only swap_used is named"         "swap_used"                    "$(MT_FREE=3000 MT_PRESSURE=1 blind)"
eq_blind "used+free given, pressure missing → only pressure is named"          "pressure"                     "$(MT_USED=4900 MT_FREE=3000 blind)"
eq_blind "all three readable (4900 / 3000 / level 1) → nothing blind, nothing to log" "" "$(MT_USED=4900 MT_FREE=3000 MT_PRESSURE=1 blind)"
eq_blind "garbage values (abc / -5 / 3) are blind too, not 'zero'"             "swap_used,swap_free,pressure" "$(MT_USED=abc MT_FREE=-5 MT_PRESSURE=3 blind)"
eq_blind "tight AND partly blind (used 8400 → tight) still reports what it could not see" "swap_free,pressure" "$(MT_USED=8400 blind)"
eq_blind "a readable 0 MB swap is a reading, not blindness"                    ""                             "$(MT_USED=0 MT_FREE=0 MT_PRESSURE=1 blind)"
R="$(MT_USED=4900 MT_PRESSURE=1 run_mt)"
expect "partly blind + not tight → still fail-OPEN (rc 1), blindness never becomes a block" 1 "" "$R"
printf 'garbage that is not the swapusage format\n' > "$WORK/swapusage"; echo 1 > "$WORK/pressure"
eq_blind "the REAL probe path: an unparseable swapusage line is named blind (the macOS-format-change case)" "swap_used,swap_free" "$(blind)"
reset

echo "T7: kill switch — PILOT_MEMORY_TIGHT_ENABLED=0 → never tight, nothing probed"
expect "disabled, swap used 9000 + pressure 4 → not tight" 1 "" "$(MT_ENABLED=0 MT_USED=9000 MT_PRESSURE=4 run_mt)" disabled
R="$(MT_ENABLED=0 MT_USED=9000 run_mt)"
case "$R" in *"|stale|stale") bad "disabled path left the previous reason/detail in place (stale globals)" ;; *"||") ok "disabled path resets reason+detail to empty" ;; *) bad "unexpected disabled-path output: $R" ;; esac
eq_blind "disabled (kill switch) is OFF, not blind: the blind list is reset to empty, so nothing is logged" "" "$(MT_ENABLED=0 blind)"

echo "T8: the REAL probe path (sysctl vm.swapusage / kern.memorystatus_vm_pressure_level / df) parses the live format"
reset
printf 'total = 9216.00M  used = 8374.00M  free = 842.00M  (encrypted)\n' > "$WORK/swapusage"
echo 1 > "$WORK/pressure"
R="$(run_mt)"
expect "sysctl swapusage used=8374M free=842M, pressure 1 → tight [swap-used]" 0 "swap-used" "$R"
case "$R" in
  *"swap_used=8374MB swap_free=842MB"*"pressure=1"*) ok "the detail carries the parsed readings" ;;
  *) bad "the detail does not carry the parsed readings: $R" ;;
esac
printf 'total = 4096.00M  used = 3000.00M  free = 1096.00M  (encrypted)\n' > "$WORK/swapusage"
expect "sysctl swapusage used=3000M free=1096M → not tight" 1 "" "$(run_mt)"
printf 'total = 4096.00M  used = 3900.00M  free = 196.00M  (encrypted)\n' > "$WORK/swapusage"
echo 2000 > "$WORK/diskfree"
expect "real probes: free 196M + df 2000M → tight [swap-exhausted]" 0 "swap-exhausted" "$(run_mt)"
echo 90000 > "$WORK/diskfree"
expect "real probes: free 196M + df 90000M → not tight (swap can grow)" 1 "" "$(run_mt)"
echo 4 > "$WORK/pressure"
expect "real probes: pressure 4 → tight [pressure-4]" 0 "pressure-4" "$(run_mt)"
printf 'garbage that is not the swapusage format\n' > "$WORK/swapusage"
rm -f "$WORK/pressure" "$WORK/diskfree"
expect "unparseable swapusage line → no signal, not tight" 1 "" "$(run_mt)"

echo "T9: drift guards — the arm is wired into the cross-stage predicate and calibrated against the measured levels"
if grep -q '_pilot_memory_tight' "$DISPATCHER" \
   && awk '/ga-d0hz3: CROSS-STAGE admission gate/{f=1} f&&/_pilot_memory_tight/{found=1} f&&/Pilot sweep complete: dispatched=0 \(deferred: cross-stage/{exit} END{exit !found}' "$DISPATCHER"; then
  ok "the cross-stage block calls _pilot_memory_tight"
else
  bad "the cross-stage block does not call _pilot_memory_tight"
fi
if awk '/ga-d0hz3: CROSS-STAGE admission gate/{f=1} f&&/\[ "\$_xstage_mem_tight" = "1" \]/{found=1} f&&/Pilot sweep complete: dispatched=0 \(deferred: cross-stage/{exit} END{exit !found}' "$DISPATCHER"; then
  ok "mem_tight is one of the OR'd terms of _xstage_resource_tight"
else
  bad "_xstage_resource_tight does not include mem_tight"
fi
if grep -q '_pilot_write_sweep_pause_state 1 "cross-stage-yield" ".*mem_tight=' "$DISPATCHER"; then
  ok "the cross-stage-yield pause state names mem_tight (the reason string stays cross-stage-yield for the reconciler)"
else
  bad "the pause-state detail does not carry mem_tight"
fi
if awk '/ga-d0hz3: CROSS-STAGE admission gate/{f=1} f&&/Memory signal UNREADABLE/{a=1} f&&/PILOT_MEM_TIGHT_BLIND/{b=1} f&&/Pilot sweep complete: dispatched=0 \(deferred: cross-stage/{exit} END{exit !(a&&b)}' "$DISPATCHER"; then
  ok "the cross-stage block logs 'Memory signal UNREADABLE' from PILOT_MEM_TIGHT_BLIND (a blind probe is on the record)"
else
  bad "the cross-stage block does not log a blind memory probe (Memory signal UNREADABLE / PILOT_MEM_TIGHT_BLIND)"
fi
DEF_MAX="$(sed -n 's/^PILOT_SWAP_USED_MAX_MB="\${PILOT_SWAP_USED_MAX_MB:-\([0-9]*\)}".*/\1/p' "$DISPATCHER" | head -1)"
if [ -n "$DEF_MAX" ] && [ "$DEF_MAX" -gt 4900 ] && [ "$DEF_MAX" -lt 8200 ]; then
  ok "the default used-swap ceiling ($DEF_MAX MB) sits between the measured healthy (4.9 GB) and starving (8.2 GB) levels"
else
  bad "the default used-swap ceiling '$DEF_MAX' is not between the measured healthy (4900) and starving (8200) MB"
fi
if grep -q '^PILOT_MEMORY_TIGHT_ENABLED="\${PILOT_MEMORY_TIGHT_ENABLED:-1}"' "$DISPATCHER"; then
  ok "the memory arm is ON by default and has a kill switch"
else
  bad "PILOT_MEMORY_TIGHT_ENABLED does not default to 1"
fi

echo "T10: syntax"
if bash -n "$DISPATCHER" 2>/dev/null; then ok "pilot-dispatcher.sh parses"; else bad "pilot-dispatcher.sh has a syntax error"; fi

echo
echo "pilot-dispatcher.memory-tight.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
