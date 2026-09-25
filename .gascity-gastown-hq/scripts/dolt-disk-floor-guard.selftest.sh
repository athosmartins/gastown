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

# ── _vm_swap_gb: real du parsing on this host's macOS virtual-memory volume
#    (NOT stubbed — proves the -k/1024/1024 math against this machine's
#    actual du output, same rationale as the _avail_gb(/tmp) test above;
#    ga-sfj3i.2) ─────────────────────────────────────────────────────────────
g="$(_vm_swap_gb)"
case "$g" in
  ''|*[!0-9]*) bad "_vm_swap_gb() did not return an integer (got: '$g')" ;;
  *) [ "$g" -ge 0 ] && ok "_vm_swap_gb() returns a non-negative integer GB ($g)" || bad "_vm_swap_gb() returned negative: $g" ;;
esac

# ── _vm_swap_gb: du failure → "" (surfaces as "unknown" in the log line,
#    never a silent 0 — same ga-p5q3 error/empty discipline as _avail_gb
#    above). Shadows `du` with a local function for exactly one call
#    (function lookup wins over PATH in bash) rather than reparameterizing
#    _vm_swap_gb, since its whole point is one fixed, non-configurable
#    target path, unlike _avail_gb's optional [path] arg. ───────────────────
du() { echo "not a number"; }
g="$(_vm_swap_gb)"
unset -f du
[ "$g" = "" ] && ok "_vm_swap_gb() → '' when du output is unparseable (failure surfaces, not masked)" || bad "_vm_swap_gb(du failure) got: '$g' (expected empty)"

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

# ── _sustain_confirmed: CRITICAL-mail debounce gate (ga-q4cqr) — the
#    boundary is >= (inclusive), and a corrupt/non-numeric pending count
#    fails CLOSED (never confirmed), the opposite direction from
#    _cooldown_elapsed's fail-open — see the function's own comment for why.
_sustain_confirmed 2 2   && ok "sustain_confirmed: pending==threshold → confirmed (boundary inclusive)" || bad "sustain_confirmed: 2>=2 should confirm"
_sustain_confirmed 3 2   && ok "sustain_confirmed: pending>threshold → confirmed"                        || bad "sustain_confirmed: 3>=2 should confirm"
_sustain_confirmed 1 2   && bad "sustain_confirmed: pending<threshold should NOT confirm"                || ok "sustain_confirmed: 1<2 → not yet confirmed"
_sustain_confirmed 0 2   && bad "sustain_confirmed: pending=0 should NOT confirm"                        || ok "sustain_confirmed: 0<2 → not yet confirmed"
_sustain_confirmed "" 2  && bad "sustain_confirmed: empty pending should fail CLOSED, not confirm"       || ok "sustain_confirmed: empty pending → fails closed (never confirmed)"
_sustain_confirmed abc 2 && bad "sustain_confirmed: non-numeric pending should fail CLOSED"              || ok "sustain_confirmed: non-numeric pending → fails closed"
_sustain_confirmed 1 1   && ok "sustain_confirmed: threshold=1 (sustain disabled/immediate) → confirmed on 1st sample" || bad "sustain_confirmed: 1>=1 should confirm"

# ── _should_mail_critical (ga-4f4opx): the CRITICAL-mail REPEAT-debounce gate
#    — cooldown-elapsed OR a new relevant minimum (avail dropped by
#    >= min_drop since the last mail). A SEPARATE track from _should_notify
#    (different state, different cooldown) even though the shape rhymes. ────
_should_mail_critical 1000 1100 7200 2 2 1   && bad "should_mail_critical: within cooldown, unchanged avail, no new minimum → should suppress" || ok "should_mail_critical: within cooldown + stable avail → suppressed (the actual ga-4f4opx bug, now fixed)"
_should_mail_critical 1000 8201 7200 2 2 1   && ok "should_mail_critical: cooldown elapsed (7201s >= 7200s) → mail again even at unchanged avail" || bad "should_mail_critical: elapsed cooldown should re-mail regardless of trend"
_should_mail_critical 1000 8200 7200 2 2 1   && ok "should_mail_critical: exactly 7200s elapsed → elapsed (boundary >=, matches _cooldown_elapsed)" || bad "should_mail_critical: boundary should be inclusive"
_should_mail_critical 1000 1100 7200 1 2 1   && ok "should_mail_critical: within cooldown BUT avail dropped by >=1GB (2→1) → new minimum, mail again" || bad "should_mail_critical: a 1GB drop should be a new relevant minimum"
_should_mail_critical 1000 1100 7200 2 3 1   && ok "should_mail_critical: within cooldown, avail dropped 3→2 (>=1GB) → new minimum, mail again" || bad "should_mail_critical: a 1GB drop (3->2) should count"
_should_mail_critical 1000 1100 7200 2 3 2   && bad "should_mail_critical: drop of 1GB (3->2) below a 2GB min_drop threshold should NOT count" || ok "should_mail_critical: drop below configured min_drop_gb → not a new minimum"
_should_mail_critical 1000 1100 7200 3 2 1   && bad "should_mail_critical: avail IMPROVED (2→3) within cooldown should NOT re-mail" || ok "should_mail_critical: improved avail (not worse) within cooldown → suppressed"
_should_mail_critical "" 1100 7200 2 "" 1    && ok "should_mail_critical: no prior mail record → mail (fail-open; the FIRST sustain-confirmed mail of an episode must never be blocked)" || bad "should_mail_critical: first-ever mail should never be suppressed"
_should_mail_critical 1000 1100 7200 2 "" 1  && bad "should_mail_critical: within cooldown + corrupt/empty last_mail_avail should fail CLOSED on the drop check (not fabricate a drop)" || ok "should_mail_critical: empty last_mail_avail (within cooldown) → drop check fails closed, suppressed"
_should_mail_critical 1000 1100 7200 "" 2 1  && bad "should_mail_critical: within cooldown + non-numeric current avail should fail CLOSED on the drop check" || ok "should_mail_critical: non-numeric current avail (within cooldown) → drop check fails closed, suppressed"

# ── _should_resurrect (ga-f4l2z): gate on CONFIRMED-down (probe_rc=1, the
#    gc_dolt_probe_robust "unreachable, confirmed" code) AND disk headroom
#    safe (class NONE/WARN only — NEVER CRITICAL: the crash-loop risk this
#    bead exists to avoid; NEVER UNKNOWN: an unmeasurable floor is never
#    "safe"). probe_rc=0 (healthy) and probe_rc=2 (unknown/transient, e.g. a
#    CPU burst) must both refuse just as hard as a bad class — resurrection
#    is only for a CONFIRMED outage, never a guess. ────────────────────────
_should_resurrect 1 NONE     && ok "should_resurrect: confirmed-down + class=NONE → true"                                       || bad "should_resurrect 1/NONE should be true"
_should_resurrect 1 WARN     && ok "should_resurrect: confirmed-down + class=WARN → true"                                        || bad "should_resurrect 1/WARN should be true"
_should_resurrect 1 CRITICAL && bad "should_resurrect: confirmed-down + class=CRITICAL must NEVER resurrect (crash-loop risk)"   || ok "should_resurrect: CRITICAL disk → false (crash-loop guard)"
_should_resurrect 1 UNKNOWN  && bad "should_resurrect: confirmed-down + class=UNKNOWN must NEVER resurrect (unmeasurable floor)" || ok "should_resurrect: UNKNOWN disk → false (unmeasurable-floor guard)"
_should_resurrect 0 NONE     && bad "should_resurrect: probe_rc=0 (healthy) must NEVER resurrect — nothing to fix"               || ok "should_resurrect: healthy probe → false (nothing to fix)"
_should_resurrect 0 WARN     && bad "should_resurrect: probe_rc=0 (healthy) must NEVER resurrect, even under disk WARN"          || ok "should_resurrect: healthy probe + WARN disk → false"
_should_resurrect 2 NONE     && bad "should_resurrect: probe_rc=2 (unknown/transient) must NEVER be conflated with confirmed-down" || ok "should_resurrect: unknown/transient probe → false (never conflate with a confirmed outage)"
_should_resurrect "" NONE    && bad "should_resurrect: empty probe_rc must NEVER resurrect"                                      || ok "should_resurrect: empty probe_rc → false"
_should_resurrect abc NONE   && bad "should_resurrect: non-numeric probe_rc must NEVER resurrect"                                || ok "should_resurrect: non-numeric probe_rc → false"

# ── _top_mem_processes: real top/ps/launchctl parsing (NOT stubbed — proves
#    field extraction matches this machine's actual `top -stats
#    pid,ppid,command,mem,cmprs` banner/column format, same rationale as the
#    _avail_gb(/tmp) and _vm_swap_gb() real tests above; ga-xz5re, replacing
#    _top_rss_processes) ────────────────────────────────────────────────
g="$(_top_mem_processes 5)"
line_count="$(printf '%s\n' "$g" | grep -c .)"
[ "$line_count" -eq 5 ] && ok "_top_mem_processes(5) returns exactly 5 lines" || bad "_top_mem_processes(5) returned $line_count lines (expected 5): $g"
g2="$(_top_mem_processes 2)"
line_count2="$(printf '%s\n' "$g2" | grep -c .)"
[ "$line_count2" -eq 2 ] && ok "_top_mem_processes(2) respects the N argument" || bad "_top_mem_processes(2) returned $line_count2 lines (expected 2)"
# each line: PID PPID MEM CMPRS LAUNCHD_LABEL FULL_COMMAND — first two
# whitespace fields must be numeric (PID, PPID) and a MEM field must be
# present. Guard explicitly on empty output first — a `while read` over an
# empty variable still iterates once with an empty line, which would
# otherwise leave bad_line at its innocent default and PASS vacuously
# (ga-p5q3: empty must never grade the same as "checked and fine").
if [ -z "$g" ]; then
  bad_line="(no output — cannot check shape)"
else
  bad_line=""
  while IFS= read -r ln; do
    pid_f="$(printf '%s' "$ln" | awk '{print $1}')"
    ppid_f="$(printf '%s' "$ln" | awk '{print $2}')"
    mem_f="$(printf '%s' "$ln" | awk '{print $3}')"
    case "$pid_f" in ''|*[!0-9]*) bad_line="$ln" ;; esac
    case "$ppid_f" in ''|*[!0-9]*) bad_line="$ln" ;; esac
    [ -z "$mem_f" ] && bad_line="$ln"
  done <<MEM_SHAPE
$g
MEM_SHAPE
fi
[ -z "$bad_line" ] && ok "_top_mem_processes: every line has numeric PID + PPID, and a non-empty MEM field" || bad "_top_mem_processes: malformed row or no output: '$bad_line'"
# Sort order is NOT reverified against real host output here (MEM/CMPRS are
# opaque, mixed-unit strings like "22G"/"584M" — top itself sorts on the
# underlying byte count before formatting, per `man top`'s "-o mem" key
# definition; the ga-xz5re fixture scenario below re-proves ordering against
# controlled, known values instead of duplicating unit-conversion logic here).

# ── _top_mem_processes: top failure → "" (surfaces as unmeasured, never a
#    silent empty-looking-like-zero-processes — same ga-p5q3 discipline the
#    old ps-failure test applied to _top_rss_processes) ────────────────────
top() { echo "not top output"; }
g="$(_top_mem_processes 5 | grep -c .)"
unset -f top
[ "$g" -eq 0 ] && ok "_top_mem_processes: unparseable top output → no rows (failure surfaces as empty, not fabricated rows)" || bad "_top_mem_processes(top failure) got $g rows (expected 0)"

# ── _top_mem_processes: ga-xz5re regression, the bead's own acceptance
#    fixture — a process whose memory is almost entirely COMPRESSED (low
#    RSS, like the incident's build_ficha360_search_index.py at
#    MEM=22G/CMPRS=22G) must rank FIRST by physical-memory footprint even
#    though the OLD ps-RSS-based listing this function replaces would never
#    have surfaced it at all. Stubs `top` (the new data source) AND `ps -Ao
#    pid,rss,comm` (the OLD data source — _top_rss_processes itself is gone
#    from the script, this just reproduces its exact invocation to prove
#    the blind spot) against the SAME five-process set, so both halves of
#    the acceptance criteria are checked against identical data instead of
#    asserted independently. Also proves the FULL command (script name)
#    surfaces — top's own COMMAND column alone would show every row here as
#    indistinguishable "Python" — and that a matched launchd label renders
#    instead of "-". ──────────────────────────────────────────────────────
top() {
  cat <<'TOPFIX'
Processes: 400 total, 3 running, 397 sleeping, 2000 threads
2026/09/11 03:00:00
Load Avg: 5.00, 5.00, 5.00
CPU usage: 10.00% user, 5.00% sys, 85.00% idle
SharedLibs: 300M resident, 40M data, 30M linkedit.
MemRegions: 100000 total, 3000M resident, 20M private, 400M shared.
PhysMem: 16G used, 200M unused.
VM: 200T vsize, 4000M framework vsize, 100(0) swapins, 200(0) swapouts.
Networks: packets: 1000/1M in, 900/1M out.
Disks: 1000/10G read, 900/10G written.

PID    PPID  COMMAND      MEM   CMPRS
89690  1     Python       22G   22G
51664  1     dolt         584M  12M
11357  1     claude       253M  4M
22222  1     claude       220M  3M
33333  1     claude        90M  1M
TOPFIX
}
ps() {
  case "$*" in
    "-Ao pid,rss,comm")
      cat <<'PSFIX'
  PID   RSS COMM
 51664 598016 dolt
 11357 259072 claude
 22222 225280 claude
 33333  92160 claude
 44444  40960 claude
 89690   3072 python3.11
PSFIX
      ;;
    "-o command= -p 89690")
      echo "/usr/bin/python3.11 /Users/t/scripts/build_ficha360_search_index.py"
      ;;
    *)
      echo ""
      ;;
  esac
}
launchctl() {
  [ "$1" = "list" ] || return 0
  printf 'PID\tStatus\tLabel\n89690\t0\tcom.gastown.ficha360-index\n51664\t0\tcom.gastown.dolt-server\n'
}

g="$(_top_mem_processes 5)"
first_line="$(printf '%s\n' "$g" | head -n1)"
first_pid="$(printf '%s' "$first_line" | awk '{print $1}')"
[ "$first_pid" = "89690" ] && ok "ga-xz5re: process with low RSS but high MEM/CMPRS (89690) ranks FIRST by footprint" || bad "ga-xz5re: expected PID 89690 first, got: $g"

old_style_top5="$(ps -Ao pid,rss,comm | tail -n +2 | sort -rn -k2 | head -n5 | awk '{print $1}')"
case "$old_style_top5" in
  *89690*) bad "ga-xz5re: fixture is invalid — PID 89690 should NOT be in the OLD RSS-based top-5 (it must reproduce the blind spot, not accidentally dodge it)" ;;
  *) ok "ga-xz5re: confirms the blind spot — PID 89690 does NOT appear anywhere in the OLD ps-RSS-based top-5" ;;
esac

first_cmd_field="$(printf '%s' "$first_line" | cut -d' ' -f6-)"
case "$first_cmd_field" in
  *build_ficha360_search_index.py*) ok "_top_mem_processes: shows the FULL command (script name), not top's truncated 'Python'" ;;
  *) bad "_top_mem_processes: full command missing from output: $first_line" ;;
esac

first_label="$(printf '%s' "$first_line" | awk '{print $5}')"
[ "$first_label" = "com.gastown.ficha360-index" ] && ok "_top_mem_processes: resolves the launchd label when one matches" || bad "_top_mem_processes: expected matched launchd label, got '$first_label'"

third_label="$(printf '%s\n' "$g" | sed -n '3p' | awk '{print $5}')"
[ "$third_label" = "-" ] && ok "_top_mem_processes: unmatched process shows LAUNCHD_LABEL='-', not a fabricated label" || bad "_top_mem_processes: expected '-' launchd label for an unmatched PID, got '$third_label'"

unset -f top ps launchctl

# ── _vm_bound_pressure: reclaimed<=0 AND vm>=threshold → VM-bound (the exact
#    ga-sfj3i incident shape: "reclaim OK — avail X -> X" while GB are stuck
#    in virtual memory) ──────────────────────────────────────────────────
_vm_bound_pressure 0 5 2   && ok "vm_bound: reclaimed=0, vm=5>=2 → VM-bound"                      || bad "vm_bound 0/5/2 should be true"
_vm_bound_pressure -3 5 2  && ok "vm_bound: reclaimed=-3 (worse), vm=5>=2 → VM-bound"              || bad "vm_bound -3/5/2 should be true"
_vm_bound_pressure 0 2 2   && ok "vm_bound: vm==threshold → VM-bound (boundary inclusive)"         || bad "vm_bound 0/2/2 should be true (inclusive boundary)"
_vm_bound_pressure 5 5 2   && bad "vm_bound: reclaimed=5 (cleanup worked) should NOT be VM-bound"  || ok "vm_bound: positive reclaim → not VM-bound"
_vm_bound_pressure 0 1 2   && bad "vm_bound: vm=1 below threshold=2 should NOT be VM-bound"        || ok "vm_bound: vm below threshold → not VM-bound"
_vm_bound_pressure 0 "" 2  && bad "vm_bound: unmeasurable vm should NEVER confirm VM-bound"        || ok "vm_bound: empty vm → not VM-bound (unmeasurable, not false-negative-as-fine)"
_vm_bound_pressure 0 abc 2 && bad "vm_bound: non-numeric vm should NEVER confirm VM-bound"         || ok "vm_bound: non-numeric vm → not VM-bound"

# ── _gocache_size_gb: real du parsing (NOT stubbed on an explicit path — same
#    rationale as the _avail_gb(/tmp)/_vm_swap_gb() real tests above; ga-yi68q) ──
g="$(_gocache_size_gb /tmp)"
case "$g" in
  ''|*[!0-9]*) bad "_gocache_size_gb(/tmp) did not return an integer (got: '$g')" ;;
  *) [ "$g" -ge 0 ] && ok "_gocache_size_gb(/tmp) returns a non-negative integer GB ($g)" || bad "_gocache_size_gb(/tmp) returned negative: $g" ;;
esac

# ── _gocache_size_gb: nonexistent path → "" (surfaces as unmeasured, never a
#    silent 0 — ga-p5q3 discipline, same as _avail_gb's own nonexistent-path test) ──
g="$(_gocache_size_gb "/nonexistent/path/$$/does-not-exist")"
[ "$g" = "" ] && ok "_gocache_size_gb(nonexistent path) → '' (du failure surfaces, not masked)" || bad "_gocache_size_gb(nonexistent) got: '$g' (expected empty)"

# ── _gocache_size_gb: default-arg path resolves via the real _gocache_dir
#    (go env GOCACHE, or the macOS-default fallback) end to end on this host.
#    Accepts EITHER a non-negative integer (dir present) OR '' (dir absent —
#    e.g. right after _reap_gocache's own `go clean -cache`, or before any
#    `go build` ever ran): both are _gocache_size_gb's documented, valid
#    outcomes — same ga-p5q3 discipline as the nonexistent-path case just
#    above, now applied to whatever this host's real dir happens to be right
#    now instead of a manufactured path. Attempt-1 gate feedback (ga-cwm2m)
#    caught this collapsing '' into a FAIL, live-reproduced on a host where
#    GOCACHE didn't exist at that instant ──────────────────────────────────
g="$(_gocache_size_gb)"
case "$g" in
  '') ok "_gocache_size_gb() (default dir) → '' — GOCACHE not present on this host right now (contractually valid, same as the nonexistent-path case above)" ;;
  *[!0-9]*) bad "_gocache_size_gb() (default dir) returned a non-empty, non-integer value (got: '$g')" ;;
  *) [ "$g" -ge 0 ] && ok "_gocache_size_gb() (default dir, real _gocache_dir resolution) returns a non-negative integer GB ($g)" || bad "_gocache_size_gb() returned negative: $g" ;;
esac

# ── _go_toolchain_active: live process-table read (NOT controllable
#    hermetically) — only proves it returns a valid boolean exit code without
#    crashing or hanging, same minimalism as this file's other live-state
#    reads (_top_mem_processes) where the real value can't be pinned ────────
_go_toolchain_active; _gta_rc=$?
if [ "$_gta_rc" -eq 0 ] || [ "$_gta_rc" -eq 1 ]; then
  ok "_go_toolchain_active: returns a valid boolean exit code ($_gta_rc) without crashing"
else
  bad "_go_toolchain_active: unexpected exit code $_gta_rc (expected 0 or 1)"
fi

# ── _should_reap_gocache (ga-yi68q): reap only when the cache is large enough
#    to matter AND (no go process active OR this cycle is CRITICAL) — mirrors
#    _should_resurrect's boundary-style coverage above ──────────────────────
_should_reap_gocache 5 3 0 0 && ok "should_reap_gocache: cache(5)>=threshold(3), go NOT active → true (WARN-tier ok)" || bad "should_reap_gocache 5/3/0/0 should be true"
_should_reap_gocache 3 3 0 0 && ok "should_reap_gocache: cache==threshold → true (boundary inclusive)" || bad "should_reap_gocache 3/3/0/0 should be true (inclusive boundary)"
_should_reap_gocache 2 3 0 0 && bad "should_reap_gocache: cache(2)<threshold(3) should NOT reap" || ok "should_reap_gocache: cache below threshold → false"
_should_reap_gocache 5 3 1 0 && bad "should_reap_gocache: go ACTIVE + was_critical=0 should NOT reap (avoid disrupting a live build at WARN)" || ok "should_reap_gocache: go active, non-critical → false (WARN-tier skip)"
_should_reap_gocache 5 3 1 1 && ok "should_reap_gocache: go ACTIVE but was_critical=1 → true (CRITICAL overrides — Dolt ENOSPC is worse than a failed build)" || bad "should_reap_gocache 5/3/1/1 should be true (CRITICAL override)"
_should_reap_gocache 5 3 0 1 && ok "should_reap_gocache: go not active + was_critical=1 → true" || bad "should_reap_gocache 5/3/0/1 should be true"
_should_reap_gocache "" 3 0 0  && bad "should_reap_gocache: empty cache_gb (du failed) should fail CLOSED, never guess" || ok "should_reap_gocache: empty cache_gb → fails closed (never reap on an unmeasured size)"
_should_reap_gocache abc 3 0 0 && bad "should_reap_gocache: non-numeric cache_gb should fail CLOSED" || ok "should_reap_gocache: non-numeric cache_gb → fails closed"

# ── _go_build_tmp_root (ga-ilmjgo): real getconf call — NOT stubbed, same
#    rationale as this file's other real-state reads (_avail_gb(/tmp) etc.) ──
r="$(_go_build_tmp_root)"
if [ -n "$r" ] && [ -d "$r" ]; then
  ok "_go_build_tmp_root(): resolved a real, existing DARWIN_USER_TEMP_DIR ($r)"
else
  bad "_go_build_tmp_root(): expected a real existing dir on this macOS host, got '$r'"
fi

# ── _go_build_dir_in_use (ga-ilmjgo): real lsof tristate — NOT stubbed, same
#    rationale as _avail_gb(/tmp)/_gocache_size_gb(/tmp) above: proves the
#    real lsof invocation + content-based parsing against this host's real
#    lsof, not a mocked one ───────────────────────────────────────────────
GBIU_EMPTY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-gbiu-empty.XXXXXX)"
_go_build_dir_in_use "$GBIU_EMPTY"; gbiu_rc=$?
if [ "$gbiu_rc" -eq 1 ]; then
  ok "_go_build_dir_in_use(empty real dir): confirmed NOT in use (rc=1)"
else
  bad "_go_build_dir_in_use(empty dir) expected rc=1 (confirmed clear), got rc=$gbiu_rc"
fi
rm -rf "$GBIU_EMPTY"

GBIU_BUSY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-gbiu-busy.XXXXXX)"
exec 8>"$GBIU_BUSY/held-open"
_go_build_dir_in_use "$GBIU_BUSY"; gbiu_rc=$?
exec 8>&-
if [ "$gbiu_rc" -eq 0 ]; then
  ok "_go_build_dir_in_use(dir with a real open fd): confirmed IN USE (rc=0)"
else
  bad "_go_build_dir_in_use(busy dir) expected rc=0 (in use), got rc=$gbiu_rc"
fi
rm -rf "$GBIU_BUSY"

# ── _should_reap_go_build_dir (ga-ilmjgo): reap ONLY when confirmed orphaned
#    (rc=1) AND past the mtime grace period — mirrors _should_reap_gocache's
#    boundary-style coverage above ─────────────────────────────────────────
_should_reap_go_build_dir 1 3600 1800 && ok "should_reap_go_build_dir: confirmed orphaned, age(3600)>=grace(1800) → true" || bad "should_reap_go_build_dir 1/3600/1800 should be true"
_should_reap_go_build_dir 1 1800 1800 && ok "should_reap_go_build_dir: age==grace → true (boundary inclusive)" || bad "should_reap_go_build_dir 1/1800/1800 should be true (inclusive boundary)"
_should_reap_go_build_dir 1 1799 1800 && bad "should_reap_go_build_dir: age(1799)<grace(1800) should NOT reap" || ok "should_reap_go_build_dir: age below grace → false (too young)"
_should_reap_go_build_dir 0 3600 1800 && bad "should_reap_go_build_dir: in_use_rc=0 (IN USE) should NEVER reap" || ok "should_reap_go_build_dir: in-use → false"
_should_reap_go_build_dir 2 3600 1800 && bad "should_reap_go_build_dir: in_use_rc=2 (UNKNOWN) should NEVER reap" || ok "should_reap_go_build_dir: unknown liveness → false (never treat unknown as safe)"
_should_reap_go_build_dir 1 "" 1800   && bad "should_reap_go_build_dir: empty age should fail CLOSED" || ok "should_reap_go_build_dir: empty age → fails closed"
_should_reap_go_build_dir 1 3600 ""   && bad "should_reap_go_build_dir: empty grace should fail CLOSED" || ok "should_reap_go_build_dir: empty grace → fails closed"
_should_reap_go_build_dir 1 abc 1800  && bad "should_reap_go_build_dir: non-numeric age should fail CLOSED" || ok "should_reap_go_build_dir: non-numeric age → fails closed"

# ── _dir_size_mb (ga-ilmjgo): real du parsing — NOT stubbed, same rationale
#    as _gocache_size_gb(/tmp) above ───────────────────────────────────────
d="$(_dir_size_mb /tmp)"
case "$d" in
  ''|*[!0-9]*) bad "_dir_size_mb(/tmp) did not return an integer (got: '$d')" ;;
  *) [ "$d" -ge 0 ] && ok "_dir_size_mb(/tmp) returns a non-negative integer MB ($d)" || bad "_dir_size_mb(/tmp) returned negative: $d" ;;
esac
d="$(_dir_size_mb "/nonexistent/path/$$/does-not-exist")"
[ "$d" = "" ] && ok "_dir_size_mb(nonexistent path) → '' (du failure surfaces, not masked)" || bad "_dir_size_mb(nonexistent) got: '$d' (expected empty)"

echo ""
echo "=== _reap_go_build_orphans (ga-ilmjgo): real directory walk, hermetic fixture ==="
# Fake TMPDIR root — NEVER the real DARWIN_USER_TEMP_DIR. Three candidates,
# matching this bead's own acceptance-test spec verbatim: an old+unowned dir
# (must delete), an old+in-use dir (real open fd, real lsof — must spare),
# and a new+unowned dir still inside the grace window (must spare).
GBT_ROOT="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-gbt.XXXXXX)"
OLD_TS="$(date -v-1H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '-1 hour' '+%Y%m%d%H%M.%S')"

OLD_ORPHAN="$GBT_ROOT/go-build111111"
mkdir -p "$OLD_ORPHAN"
echo "orphan payload" > "$OLD_ORPHAN/payload"
touch -t "$OLD_TS" "$OLD_ORPHAN"

OLD_INUSE="$GBT_ROOT/go-build222222"
mkdir -p "$OLD_INUSE"
touch -t "$OLD_TS" "$OLD_INUSE"
exec 8>"$OLD_INUSE/held-open"   # real open fd — real lsof will see this

NEW_ORPHAN="$GBT_ROOT/go-build333333"
mkdir -p "$NEW_ORPHAN"
echo "fresh" > "$NEW_ORPHAN/payload"   # mtime defaults to now — inside grace

# shellcheck disable=SC2034  # read by _reap_go_build_orphans in the sourced script
GO_BUILD_ORPHAN_GRACE_SECS=1800
_reap_go_build_orphans "$GBT_ROOT"
exec 8>&-   # release the held-open fd now that the reap already ran

if [ ! -d "$OLD_ORPHAN" ]; then
  ok "_reap_go_build_orphans: old + unowned dir DELETED"
else
  bad "_reap_go_build_orphans: old + unowned dir should have been DELETED, still present"
fi
if [ -d "$OLD_INUSE" ]; then
  ok "_reap_go_build_orphans: old + IN-USE dir (real open fd, real lsof) SPARED"
else
  bad "_reap_go_build_orphans: old + in-use dir should NEVER be deleted, was removed"
fi
if [ -d "$NEW_ORPHAN" ]; then
  ok "_reap_go_build_orphans: new + unowned dir (within grace window) SPARED"
else
  bad "_reap_go_build_orphans: new + unowned dir should be spared by the grace period, was removed"
fi
rm -rf "$GBT_ROOT"

echo ""
echo "=== _reap_go_build_orphans (ga-ilmjgo): lsof failure → nothing deleted ==="
# ga-ilmjgo item 3: "erro não é vazio" — a failing lsof must NEVER be read as
# a confirmed-clear directory. Shadow lsof on PATH with a fake that fails.
GBT_ROOT2="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-gbt2.XXXXXX)"
OLD_ORPHAN2="$GBT_ROOT2/go-build444444"
mkdir -p "$OLD_ORPHAN2"
touch -t "$OLD_TS" "$OLD_ORPHAN2"

FAKE_LSOF_DIR="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-lsof.XXXXXX)"
cat > "$FAKE_LSOF_DIR/lsof" <<'EOF'
#!/bin/bash
echo "lsof: simulated failure (selftest)" >&2
exit 1
EOF
chmod +x "$FAKE_LSOF_DIR/lsof"

REAL_PATH="$PATH"
PATH="$FAKE_LSOF_DIR:$PATH"
# shellcheck disable=SC2034  # read by _reap_go_build_orphans in the sourced script
GO_BUILD_ORPHAN_GRACE_SECS=1800
_reap_go_build_orphans "$GBT_ROOT2"
PATH="$REAL_PATH"

if [ -d "$OLD_ORPHAN2" ]; then
  ok "_reap_go_build_orphans: lsof failure (nonzero exit + stderr) → dir SPARED, never guessed as orphaned"
else
  bad "_reap_go_build_orphans: lsof failure should have spared the dir — it was deleted anyway (unknown treated as safe, the exact ga-p5q3 regression this bead exists to prevent)"
fi
rm -rf "$GBT_ROOT2" "$FAKE_LSOF_DIR"

# ── _reap_go_build_orphans: nonexistent root → SKIP cleanly, never crash ───
_reap_go_build_orphans "/nonexistent/path/$$/go-build-tmp-does-not-exist"
ok "_reap_go_build_orphans: nonexistent root skips cleanly (no crash — this line only runs if it didn't)"

echo ""
echo "=== _code_sign_clone_root / _code_sign_clone_dir_in_use / _should_reap_code_sign_clone_dir (ga-nkqook) ==="
# ── _code_sign_clone_root: real getconf-derived path — NOT stubbed, same
#    rationale as _go_build_tmp_root above. Only asserts it resolves to a
#    non-empty path under the real DARWIN_USER_TEMP_DIR's parent — the actual
#    "X/com.google.Chrome.code_sign_clone" leaf need not exist on every host
#    (it only appears after macOS has actually cloned a running Chrome), so
#    this does NOT require -d like _go_build_tmp_root's check does ──────────
r="$(_code_sign_clone_root)"
case "$r" in
  */X/com.google.Chrome.code_sign_clone) ok "_code_sign_clone_root(): resolved to the expected .../X/com.google.Chrome.code_sign_clone shape ($r)" ;;
  *) bad "_code_sign_clone_root(): expected a path ending in /X/com.google.Chrome.code_sign_clone, got '$r'" ;;
esac

# ── _code_sign_clone_dir_in_use: real lsof tristate — identical contract to
#    _go_build_dir_in_use, proven independently here since it's a separate
#    (deliberately duplicated, see its own header) function ────────────────
CSCIU_EMPTY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-csciu-empty.XXXXXX)"
_code_sign_clone_dir_in_use "$CSCIU_EMPTY"; csciu_rc=$?
if [ "$csciu_rc" -eq 1 ]; then
  ok "_code_sign_clone_dir_in_use(empty real dir): confirmed NOT in use (rc=1)"
else
  bad "_code_sign_clone_dir_in_use(empty dir) expected rc=1 (confirmed clear), got rc=$csciu_rc"
fi
rm -rf "$CSCIU_EMPTY"

CSCIU_BUSY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-csciu-busy.XXXXXX)"
exec 8>"$CSCIU_BUSY/held-open"
_code_sign_clone_dir_in_use "$CSCIU_BUSY"; csciu_rc=$?
exec 8>&-
if [ "$csciu_rc" -eq 0 ]; then
  ok "_code_sign_clone_dir_in_use(dir with a real open fd): confirmed IN USE (rc=0)"
else
  bad "_code_sign_clone_dir_in_use(busy dir) expected rc=0 (in use), got rc=$csciu_rc"
fi
rm -rf "$CSCIU_BUSY"

# ── _should_reap_code_sign_clone_dir: identical boundary coverage to
#    _should_reap_go_build_dir above ────────────────────────────────────────
_should_reap_code_sign_clone_dir 1 3600 1800 && ok "should_reap_code_sign_clone_dir: confirmed orphaned, age(3600)>=grace(1800) → true" || bad "should_reap_code_sign_clone_dir 1/3600/1800 should be true"
_should_reap_code_sign_clone_dir 1 1800 1800 && ok "should_reap_code_sign_clone_dir: age==grace → true (boundary inclusive)" || bad "should_reap_code_sign_clone_dir 1/1800/1800 should be true (inclusive boundary)"
_should_reap_code_sign_clone_dir 1 1799 1800 && bad "should_reap_code_sign_clone_dir: age(1799)<grace(1800) should NOT reap" || ok "should_reap_code_sign_clone_dir: age below grace → false (too young)"
_should_reap_code_sign_clone_dir 0 3600 1800 && bad "should_reap_code_sign_clone_dir: in_use_rc=0 (IN USE) should NEVER reap" || ok "should_reap_code_sign_clone_dir: in-use → false"
_should_reap_code_sign_clone_dir 2 3600 1800 && bad "should_reap_code_sign_clone_dir: in_use_rc=2 (UNKNOWN) should NEVER reap" || ok "should_reap_code_sign_clone_dir: unknown liveness → false (never treat unknown as safe)"
_should_reap_code_sign_clone_dir 1 "" 1800   && bad "should_reap_code_sign_clone_dir: empty age should fail CLOSED" || ok "should_reap_code_sign_clone_dir: empty age → fails closed"
_should_reap_code_sign_clone_dir 1 3600 ""   && bad "should_reap_code_sign_clone_dir: empty grace should fail CLOSED" || ok "should_reap_code_sign_clone_dir: empty grace → fails closed"
_should_reap_code_sign_clone_dir 1 abc 1800  && bad "should_reap_code_sign_clone_dir: non-numeric age should fail CLOSED" || ok "should_reap_code_sign_clone_dir: non-numeric age → fails closed"

echo ""
echo "=== _reap_code_sign_clone_orphans (ga-nkqook): real directory walk, hermetic fixture ==="
# Same three-candidate shape as _reap_go_build_orphans's fixture above: an
# old+unowned dir (must delete), an old+in-use dir (real open fd, real lsof —
# must spare), and a new+unowned dir still inside the grace window (must
# spare). Naming mirrors the real code_sign_clone.<6-char-token> shape.
CSC_ROOT="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-csc.XXXXXX)"

CSC_OLD_ORPHAN="$CSC_ROOT/code_sign_clone.AAAAAA"
mkdir -p "$CSC_OLD_ORPHAN"
echo "orphan payload" > "$CSC_OLD_ORPHAN/payload"
touch -t "$OLD_TS" "$CSC_OLD_ORPHAN"

CSC_OLD_INUSE="$CSC_ROOT/code_sign_clone.BBBBBB"
mkdir -p "$CSC_OLD_INUSE"
touch -t "$OLD_TS" "$CSC_OLD_INUSE"
exec 8>"$CSC_OLD_INUSE/held-open"   # real open fd — real lsof will see this

CSC_NEW_ORPHAN="$CSC_ROOT/code_sign_clone.CCCCCC"
mkdir -p "$CSC_NEW_ORPHAN"
echo "fresh" > "$CSC_NEW_ORPHAN/payload"   # mtime defaults to now — inside grace

# shellcheck disable=SC2034  # read by _reap_code_sign_clone_orphans in the sourced script
CODE_SIGN_CLONE_ORPHAN_GRACE_SECS=1800
_reap_code_sign_clone_orphans "$CSC_ROOT"
exec 8>&-   # release the held-open fd now that the reap already ran

if [ ! -d "$CSC_OLD_ORPHAN" ]; then
  ok "_reap_code_sign_clone_orphans: old + unowned dir DELETED"
else
  bad "_reap_code_sign_clone_orphans: old + unowned dir should have been DELETED, still present"
fi
if [ -d "$CSC_OLD_INUSE" ]; then
  ok "_reap_code_sign_clone_orphans: old + IN-USE dir (real open fd, real lsof) SPARED"
else
  bad "_reap_code_sign_clone_orphans: old + in-use dir should NEVER be deleted, was removed"
fi
if [ -d "$CSC_NEW_ORPHAN" ]; then
  ok "_reap_code_sign_clone_orphans: new + unowned dir (within grace window) SPARED"
else
  bad "_reap_code_sign_clone_orphans: new + unowned dir should be spared by the grace period, was removed"
fi
rm -rf "$CSC_ROOT"

echo ""
echo "=== _reap_code_sign_clone_orphans (ga-nkqook): lsof failure → nothing deleted ==="
CSC_ROOT2="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-csc2.XXXXXX)"
CSC_OLD_ORPHAN2="$CSC_ROOT2/code_sign_clone.DDDDDD"
mkdir -p "$CSC_OLD_ORPHAN2"
touch -t "$OLD_TS" "$CSC_OLD_ORPHAN2"

CSC_FAKE_LSOF_DIR="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-lsof2.XXXXXX)"
cat > "$CSC_FAKE_LSOF_DIR/lsof" <<'EOF'
#!/bin/bash
echo "lsof: simulated failure (selftest)" >&2
exit 1
EOF
chmod +x "$CSC_FAKE_LSOF_DIR/lsof"

REAL_PATH="$PATH"
PATH="$CSC_FAKE_LSOF_DIR:$PATH"
# shellcheck disable=SC2034  # read by _reap_code_sign_clone_orphans in the sourced script
CODE_SIGN_CLONE_ORPHAN_GRACE_SECS=1800
_reap_code_sign_clone_orphans "$CSC_ROOT2"
PATH="$REAL_PATH"

if [ -d "$CSC_OLD_ORPHAN2" ]; then
  ok "_reap_code_sign_clone_orphans: lsof failure (nonzero exit + stderr) → dir SPARED, never guessed as orphaned"
else
  bad "_reap_code_sign_clone_orphans: lsof failure should have spared the dir — it was deleted anyway (unknown treated as safe)"
fi
rm -rf "$CSC_ROOT2" "$CSC_FAKE_LSOF_DIR"

echo ""
echo "=== _reap_code_sign_clone_orphans (ga-hxki9f): empty-but-'successful' lsof snapshot → nothing deleted ==="
# A whole-system `lsof -Fn` that exits 0 with COMPLETELY EMPTY stdout AND
# stderr is never a legitimate "nothing open on this host" result (unlike a
# per-directory `lsof +D <dir>` check, where empty genuinely means "nothing
# found here"). Prior to ga-hxki9f's fix, the snapshot skip-gate only caught
# timeout or empty-stdout-WITH-stderr, so this exact shape (a quietly-broken
# or PATH-shadowed lsof) slipped through and every candidate read as
# "confirmed orphaned" off one bad snapshot. Prove it with a REAL held-open
# fd on an OLD dir: if the gate is broken, this in-use dir gets deleted.
CSC_ROOT3="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-csc3.XXXXXX)"
CSC_OLD_INUSE3="$CSC_ROOT3/code_sign_clone.EEEEEE"
mkdir -p "$CSC_OLD_INUSE3"
exec 8>"$CSC_OLD_INUSE3/held-open"   # real open fd
touch -t "$OLD_TS" "$CSC_OLD_INUSE3"   # mtime set AFTER the fd's file is created — creating a file inside a dir bumps the dir's OWN mtime back to "now"

CSC_FAKE_LSOF_DIR3="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-lsof3.XXXXXX)"
cat > "$CSC_FAKE_LSOF_DIR3/lsof" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$CSC_FAKE_LSOF_DIR3/lsof"

REAL_PATH="$PATH"
PATH="$CSC_FAKE_LSOF_DIR3:$PATH"
# shellcheck disable=SC2034  # read by _reap_code_sign_clone_orphans in the sourced script
CODE_SIGN_CLONE_ORPHAN_GRACE_SECS=1800
_reap_code_sign_clone_orphans "$CSC_ROOT3"
PATH="$REAL_PATH"
exec 8>&-

if [ -d "$CSC_OLD_INUSE3" ]; then
  ok "_reap_code_sign_clone_orphans: empty-but-successful lsof snapshot (rc=0, no stdout, no stderr) → in-use dir SPARED, never guessed as orphaned"
else
  bad "_reap_code_sign_clone_orphans: empty-but-successful lsof snapshot deleted a dir with a REAL open fd — a quiet lsof failure was trusted as 'confirmed nothing in use'"
fi
rm -rf "$CSC_ROOT3" "$CSC_FAKE_LSOF_DIR3"

echo ""
echo "=== _reap_code_sign_clone_orphans (ga-hxki9f): sibling dir whose name is a PREFIX must not cross-match ==="
# code_sign_clone.AB vs code_sign_clone.ABC: an open file inside ABC must
# never make AB read as in-use (the exact false-cross-match this bead's
# review named). Exercises the real _code_sign_clone_dir_in_use grep-prefix
# guard end-to-end, not just the boundary-value unit tests above.
CSC_ROOT4="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-csc4.XXXXXX)"
CSC_PREFIX_SHORT="$CSC_ROOT4/code_sign_clone.AB"
CSC_PREFIX_LONG="$CSC_ROOT4/code_sign_clone.ABC"
mkdir -p "$CSC_PREFIX_SHORT" "$CSC_PREFIX_LONG"
exec 8>"$CSC_PREFIX_LONG/held-open"   # real open fd, ONLY inside the longer sibling
touch -t "$OLD_TS" "$CSC_PREFIX_SHORT" "$CSC_PREFIX_LONG"   # both old enough to reap if (mis)read as orphaned

# shellcheck disable=SC2034  # read by _reap_code_sign_clone_orphans in the sourced script
CODE_SIGN_CLONE_ORPHAN_GRACE_SECS=1800
_reap_code_sign_clone_orphans "$CSC_ROOT4"
exec 8>&-

if [ ! -d "$CSC_PREFIX_SHORT" ]; then
  ok "_reap_code_sign_clone_orphans: code_sign_clone.AB (genuinely orphaned) DELETED despite sharing a prefix with an in-use sibling"
else
  bad "_reap_code_sign_clone_orphans: code_sign_clone.AB should have been deleted (genuinely orphaned) — spared instead"
fi
if [ -d "$CSC_PREFIX_LONG" ]; then
  ok "_reap_code_sign_clone_orphans: code_sign_clone.ABC (real open fd) SPARED — its shorter-name sibling's grep pattern did not cross-match it"
else
  bad "_reap_code_sign_clone_orphans: code_sign_clone.ABC has a REAL open fd but was deleted — a shorter sibling's prefix pattern cross-matched it (missing prefix boundary)"
fi
rm -rf "$CSC_ROOT4"

# ── _reap_code_sign_clone_orphans: nonexistent root → SKIP cleanly ──────────
_reap_code_sign_clone_orphans "/nonexistent/path/$$/code-sign-clone-does-not-exist"
ok "_reap_code_sign_clone_orphans: nonexistent root skips cleanly (no crash — this line only runs if it didn't)"

echo ""
echo "=== _bash_edit_diff_root / _should_reap_bash_edit_diff_dir (ga-ofi307) ==="
# ── _bash_edit_diff_root: real $(id -u)-derived path — NOT stubbed, same
#    rationale as _code_sign_clone_root's own shape test above ─────────────
r="$(_bash_edit_diff_root)"
case "$r" in
  /private/tmp/claude-*/bash-edit-diff) ok "_bash_edit_diff_root(): resolved to the expected /private/tmp/claude-<uid>/bash-edit-diff shape ($r)" ;;
  *) bad "_bash_edit_diff_root(): expected /private/tmp/claude-<uid>/bash-edit-diff shape, got '$r'" ;;
esac

# ── _should_reap_bash_edit_diff_dir: age-ONLY boundary coverage — no
#    liveness arg, unlike _should_reap_go_build_dir/_should_reap_code_sign_
#    clone_dir above (ga-ofi307: no PID/session correlation exists for this
#    directory class — see BASH_EDIT_DIFF_ORPHAN_GRACE_SECS's own comment) ──
_should_reap_bash_edit_diff_dir 7200 7200 && ok "should_reap_bash_edit_diff_dir: age==grace → true (boundary inclusive)" || bad "should_reap_bash_edit_diff_dir 7200/7200 should be true (inclusive boundary)"
_should_reap_bash_edit_diff_dir 7201 7200 && ok "should_reap_bash_edit_diff_dir: age(7201)>=grace(7200) → true" || bad "should_reap_bash_edit_diff_dir 7201/7200 should be true"
_should_reap_bash_edit_diff_dir 7199 7200 && bad "should_reap_bash_edit_diff_dir: age(7199)<grace(7200) should NOT reap" || ok "should_reap_bash_edit_diff_dir: age below grace → false (too young)"
_should_reap_bash_edit_diff_dir "" 7200   && bad "should_reap_bash_edit_diff_dir: empty age should fail CLOSED" || ok "should_reap_bash_edit_diff_dir: empty age → fails closed"
_should_reap_bash_edit_diff_dir 7200 ""   && bad "should_reap_bash_edit_diff_dir: empty grace should fail CLOSED" || ok "should_reap_bash_edit_diff_dir: empty grace → fails closed"
_should_reap_bash_edit_diff_dir abc 7200  && bad "should_reap_bash_edit_diff_dir: non-numeric age should fail CLOSED" || ok "should_reap_bash_edit_diff_dir: non-numeric age → fails closed"

echo ""
echo "=== _reap_bash_edit_diff_orphans (ga-ofi307): real directory walk, hermetic fixture ==="
# WHY: the real incident this bead exists for — a 3.5GB, 38-directory cache
# under /private/tmp/claude-<uid>/bash-edit-diff/ that every OTHER lever in
# this file was blind to (acceptance test 1: "disco abaixo do piso + cache de
# diff grande e antigo -> o guard libera e reporta o ganho real"). Two
# candidates: an OLD dir (must delete, with a real measurable payload so the
# freed-MB assertion below is meaningful, not a rounds-to-zero artifact) and
# a NEW dir still inside the grace window (must spare) — no in-use candidate,
# unlike the go-build/code-sign-clone fixtures above, since this lever has NO
# liveness check to exercise (age is the only signal, by design — see this
# lever's own header).
BED_ROOT="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-bed.XXXXXX)"

BED_OLD="$BED_ROOT/10730595755780137790-4591840309193377447-96a4180e768d522b"
mkdir -p "$BED_OLD/objects"
head -c 5242880 /dev/zero > "$BED_OLD/index" 2>/dev/null   # 5MB — real, measurable payload
touch -t "$OLD_TS" "$BED_OLD"

BED_NEW="$BED_ROOT/4342029083087454221-9927937567073590141-0a886f1dc6265784"
mkdir -p "$BED_NEW/objects"
echo "fresh" > "$BED_NEW/index"   # mtime defaults to now — inside grace

# shellcheck disable=SC2034  # read by _reap_bash_edit_diff_orphans in the sourced script
# 1800s (not the production 7200s default — already covered by the boundary
# tests above): OLD_TS is shared with the go-build/code-sign-clone fixtures
# above and is fixed at "1 hour ago", so the grace value here just needs to
# stay below that, same convention those fixtures already use.
BASH_EDIT_DIFF_ORPHAN_GRACE_SECS=1800
_reap_bash_edit_diff_orphans "$BED_ROOT"

if [ ! -d "$BED_OLD" ]; then
  ok "_reap_bash_edit_diff_orphans: old (>=grace) cache dir DELETED"
else
  bad "_reap_bash_edit_diff_orphans: old cache dir should have been DELETED, still present"
fi
if [ -d "$BED_NEW" ]; then
  ok "_reap_bash_edit_diff_orphans: new (within grace) cache dir SPARED"
else
  bad "_reap_bash_edit_diff_orphans: new cache dir should be spared by the grace period, was removed"
fi
if grep -qE "bash-edit-diff-reap: .*— DELETED" "$LOG" 2>/dev/null && grep -qE "bash-edit-diff-reap: considered=2 freed=[1-9][0-9]*MB( |$)" "$LOG" 2>/dev/null; then
  ok "_reap_bash_edit_diff_orphans: logs a real per-candidate DELETED line AND a non-zero measured MB gain (acceptance test 1 — reports real gain, not silence)"
else
  bad "_reap_bash_edit_diff_orphans: expected a DELETED line and a non-zero freed=NMB summary, log tail: $(tail -6 "$LOG" 2>/dev/null | tr '\n' ';')"
fi
rm -rf "$BED_ROOT"

# ── _reap_bash_edit_diff_orphans: nonexistent root → SKIP cleanly, never crash ──
_reap_bash_edit_diff_orphans "/nonexistent/path/$$/bash-edit-diff-does-not-exist"
ok "_reap_bash_edit_diff_orphans: nonexistent root skips cleanly (no crash — this line only runs if it didn't)"

echo ""
echo "=== _is_test_dolt_config_path (ga-fqj42) ==="
# Mirrors third_party/beads/scripts/clean-test-tmp.sh's six canonical
# cmd/bd test-tmp-dir prefixes verbatim (same list disk-pressure-monitor.sh
# pass 14 already uses) — all six must match, and a production config path
# must never match any of them.
_is_test_dolt_config_path "/tmp/beads-bd-tests-abc123/.dolt/config.yaml" && ok "beads-bd-tests- prefix matches" || bad "beads-bd-tests- prefix should match"
_is_test_dolt_config_path "/tmp/beads-shared-server-bd-xyz/config.yaml" && ok "beads-shared-server-bd- prefix matches" || bad "beads-shared-server-bd- prefix should match"
_is_test_dolt_config_path "/tmp/bd-testbin-000/x" && ok "bd-testbin- prefix matches" || bad "bd-testbin- prefix should match"
_is_test_dolt_config_path "/tmp/bd-init-test-000/x" && ok "bd-init-test- prefix matches" || bad "bd-init-test- prefix should match"
_is_test_dolt_config_path "/tmp/bd-init-permissions-test-000/x" && ok "bd-init-permissions-test- prefix matches" || bad "bd-init-permissions-test- prefix should match"
_is_test_dolt_config_path "/tmp/bd-embedded-init-test-000/x" && ok "bd-embedded-init-test- prefix matches" || bad "bd-embedded-init-test- prefix should match"
_is_test_dolt_config_path "/Users/athos/gt/.gascity-gastown-hq/.gc/runtime/packs/dolt/dolt-config.yaml" && bad "production config path should NEVER match" || ok "production config path correctly does not match (verified live 2026-09-18: prod's real --config value)"
_is_test_dolt_config_path "" && bad "empty config path should never match (fails closed)" || ok "empty config path correctly fails closed"

echo ""
echo "=== _reap_orphan_test_dolt_processes (ga-fqj42): real pgrep/ps walk, hermetic fixture ==="
# WHY: the real incident this bead exists for — a `dolt sql-server` TEST
# instance (pid 4768, 25min, 785MB, 2026-09-10) reparented to launchd after
# its parent `go test -tags=integration ./cmd/bd/...` run died, mis-classified
# "active server or non-test path" by gc dolt-cleanup's own allowlist and left
# running. Four candidates, faked via pgrep/ps shadowed on PATH (no real
# process is ever touched — DOLT_DISK_FLOOR_GUARD_KILL_SINK captures pids
# instead of signaling them):
#   99991 — TRUE orphan: comm=dolt, ppid=1, --config under a known test-tmp
#           prefix -> must be KILLED (appears in the sink).
#   99992 — production look-alike: comm=dolt, ppid=1 (production IS a
#           launchd-owned daemon too -- ppid=1 alone is never sufficient),
#           --config NOT under any test-tmp prefix -> must be SPARED.
#   99993 — pgrep false-positive: comm is NOT dolt (simulates pgrep -f
#           'dolt sql-server' matching a claude agent session whose own
#           injected system prompt embeds that literal string, ga-0bjqix)
#           -> must be SPARED via the basename check, before its
#           ppid/--config are ever inspected.
#   99994 — still-live test run: comm=dolt, ppid=5678 (still parented to its
#           own `go test` process, not yet orphaned), --config under a known
#           test-tmp prefix -> must be SPARED (ppid != 1).
ODP_FAKEBIN="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-odp-bin.XXXXXX)"
cat > "$ODP_FAKEBIN/pgrep" <<'EOF'
#!/bin/bash
echo 99991
echo 99992
echo 99993
echo 99994
EOF
chmod +x "$ODP_FAKEBIN/pgrep"

cat > "$ODP_FAKEBIN/ps" <<'EOF'
#!/bin/bash
field=""; pid=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) field="$2"; shift 2 ;;
    -p) pid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid" in
  99991)
    case "$field" in
      comm=) echo "/usr/local/bin/dolt" ;;
      ppid=) echo "    1" ;;
      command=) echo "dolt sql-server --config /tmp/beads-bd-tests-abc123/.dolt/config.yaml --port 12345" ;;
    esac ;;
  99992)
    case "$field" in
      comm=) echo "/usr/local/bin/dolt" ;;
      ppid=) echo "    1" ;;
      command=) echo "dolt sql-server --config /Users/athos/gt/.gascity-gastown-hq/.gc/runtime/packs/dolt/dolt-config.yaml" ;;
    esac ;;
  99993)
    case "$field" in
      comm=) echo "/usr/local/bin/claude" ;;
      ppid=) echo "    1" ;;
      command=) echo "claude --system-prompt has the literal text dolt sql-server embedded in it" ;;
    esac ;;
  99994)
    case "$field" in
      comm=) echo "/usr/local/bin/dolt" ;;
      ppid=) echo " 5678" ;;
      command=) echo "dolt sql-server --config /tmp/beads-bd-tests-def456/.dolt/config.yaml" ;;
    esac ;;
esac
EOF
chmod +x "$ODP_FAKEBIN/ps"

ODP_SINK="$(mktemp /tmp/dolt-disk-floor-guard-selftest-odp-sink.XXXXXX)"
REAL_PATH="$PATH"
PATH="$ODP_FAKEBIN:$PATH"
DOLT_DISK_FLOOR_GUARD_KILL_SINK="$ODP_SINK" _reap_orphan_test_dolt_processes
PATH="$REAL_PATH"

if grep -qx 99991 "$ODP_SINK" 2>/dev/null; then
  ok "_reap_orphan_test_dolt_processes: true orphan (ppid=1, test-tmp --config) KILLED"
else
  bad "_reap_orphan_test_dolt_processes: true orphan should have been killed, sink: $(cat "$ODP_SINK" 2>/dev/null | tr '\n' ';')"
fi
if grep -qx 99992 "$ODP_SINK" 2>/dev/null; then
  bad "_reap_orphan_test_dolt_processes: production look-alike (ppid=1, non-test --config) must NEVER be killed"
else
  ok "_reap_orphan_test_dolt_processes: production look-alike SPARED (ppid==1 alone is never sufficient)"
fi
if grep -qx 99993 "$ODP_SINK" 2>/dev/null; then
  bad "_reap_orphan_test_dolt_processes: non-dolt pgrep false-positive must NEVER be killed"
else
  ok "_reap_orphan_test_dolt_processes: pgrep false-positive (basename != dolt) SPARED"
fi
if grep -qx 99994 "$ODP_SINK" 2>/dev/null; then
  bad "_reap_orphan_test_dolt_processes: still-parented (ppid!=1) test server must NEVER be killed"
else
  ok "_reap_orphan_test_dolt_processes: still-parented test server SPARED (ppid != 1)"
fi
if grep -qE "orphan-test-dolt-reap: pid=99991 .* KILLED" "$LOG" 2>/dev/null; then
  ok "_reap_orphan_test_dolt_processes: logs a KILLED line for the true orphan"
else
  bad "_reap_orphan_test_dolt_processes: expected a KILLED log line for pid=99991, log tail: $(tail -8 "$LOG" 2>/dev/null | tr '\n' ';')"
fi
rm -rf "$ODP_FAKEBIN"
rm -f "$ODP_SINK"

echo ""
echo "=== _reap_orphan_test_dolt_processes (ga-fqj42): canonical production PID excluded even if it coincidentally matches the config-path check (defense in depth) ==="
# A synthetic worst case: pid 99995 looks EXACTLY like a true orphan (comm=dolt,
# ppid=1, --config under a known test-tmp prefix) — but dolt_server_pid (the
# SAME basename==dolt + live-LISTEN-socket-verified resolver every other
# destructive Dolt lever in this city already trusts, ga-0bjqix) is stubbed to
# name it as the canonical production server. It must still be spared: the
# exclusion is unconditional, not merely "whichever check happens to disagree
# with production."
ODP_FAKEBIN2="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-odp-bin2.XXXXXX)"
cat > "$ODP_FAKEBIN2/pgrep" <<'EOF'
#!/bin/bash
echo 99995
EOF
chmod +x "$ODP_FAKEBIN2/pgrep"
cat > "$ODP_FAKEBIN2/ps" <<'EOF'
#!/bin/bash
field=""; pid=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) field="$2"; shift 2 ;;
    -p) pid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$field" in
  comm=) echo "/usr/local/bin/dolt" ;;
  ppid=) echo "    1" ;;
  command=) echo "dolt sql-server --config /tmp/beads-bd-tests-lookalike/.dolt/config.yaml" ;;
esac
EOF
chmod +x "$ODP_FAKEBIN2/ps"

dolt_server_pid() { echo 99995; }
ODP_SINK2="$(mktemp /tmp/dolt-disk-floor-guard-selftest-odp-sink2.XXXXXX)"
REAL_PATH="$PATH"
PATH="$ODP_FAKEBIN2:$PATH"
DOLT_DISK_FLOOR_GUARD_KILL_SINK="$ODP_SINK2" _reap_orphan_test_dolt_processes
PATH="$REAL_PATH"
unset -f dolt_server_pid

if grep -qx 99995 "$ODP_SINK2" 2>/dev/null; then
  bad "_reap_orphan_test_dolt_processes: dolt_server_pid-resolved canonical production PID must NEVER be killed, even if its config path also happens to match a test-tmp prefix"
else
  ok "_reap_orphan_test_dolt_processes: canonical production PID excluded unconditionally (defense in depth beyond the config-path check alone)"
fi
rm -rf "$ODP_FAKEBIN2"
rm -f "$ODP_SINK2"

# ── _reap_orphan_test_dolt_processes: ENABLED=0 kill switch → SKIP, no pgrep call ──
ODP_SINK3="$(mktemp /tmp/dolt-disk-floor-guard-selftest-odp-sink3.XXXXXX)"
ENABLED=0 DOLT_DISK_FLOOR_GUARD_KILL_SINK="$ODP_SINK3" _reap_orphan_test_dolt_processes
if [ ! -s "$ODP_SINK3" ] && grep -q "orphan-test-dolt-reap SKIP.*ENABLED=0" "$LOG" 2>/dev/null; then
  ok "_reap_orphan_test_dolt_processes: DOLT_DISK_FLOOR_GUARD_ENABLED=0 skips the whole lever"
else
  bad "_reap_orphan_test_dolt_processes: ENABLED=0 should skip cleanly with no candidates touched"
fi
rm -f "$ODP_SINK3"

echo ""
echo "=== _safe_reclaim (ga-ofi307): zero-gain wording must not read as calm 'OK' ==="
# WHY: the real incident this bead exists for — 'gc dolt-cleanup --force' ran
# successfully (exit 0) but froze nothing, and the OLD wording logged
# "reclaim OK — avail 7GB -> 7GB" verbatim, live, 2026-09-17 20:36 — the exact
# misleading-success shape this bead names ("a forma mais enganosa de falha:
# le como sucesso"). GC and gc_dolt_probe stubbed so this exercises ONLY the
# wording/condition logic, never a real dolt-cleanup write or a real (if
# read-only) probe against this host's actual live Dolt server.
gc_dolt_probe() { return 0; }   # confirmed-healthy, so _safe_reclaim proceeds
GC=true                          # harmless no-op standing in for dolt-cleanup, exit 0

_avail_gb() { echo "7"; }        # before=7 (arg) -> after=7: zero gain, still <= warn floor(8)
_safe_reclaim 7
if grep -q "reclaim ZERO GAIN — avail 7GB -> 7GB" "$LOG" 2>/dev/null; then
  ok "_safe_reclaim: zero gain while still at/below floor logs 'ZERO GAIN', never calm 'OK'"
else
  bad "_safe_reclaim: expected a 'reclaim ZERO GAIN' line, log tail: $(tail -3 "$LOG" 2>/dev/null | tr '\n' ';')"
fi
if grep -qE '\] reclaim OK — avail 7GB -> 7GB' "$LOG" 2>/dev/null; then
  bad "_safe_reclaim: MUST NOT log the old calm 'reclaim OK' wording for a zero-gain, still-below-floor cycle"
else
  ok "_safe_reclaim: does not log the old misleading 'reclaim OK' wording for this cycle"
fi

_avail_gb() { echo "20"; }       # after=20: real gain, back above floor
_safe_reclaim 7
if grep -q "reclaim OK — avail 7GB -> 20GB" "$LOG" 2>/dev/null; then
  ok "_safe_reclaim: a real gain still logs plain 'OK' (opposite remedies stay distinguishable — ga-sfj3i.3 discipline)"
else
  bad "_safe_reclaim: expected 'reclaim OK — avail 7GB -> 20GB' for a real gain, log tail: $(tail -3 "$LOG" 2>/dev/null | tr '\n' ';')"
fi

_avail_gb() { echo "20"; }       # before=20, after=20: zero gain, but NEVER actually below floor
_safe_reclaim 20
if grep -q "reclaim OK — avail 20GB -> 20GB" "$LOG" 2>/dev/null; then
  ok "_safe_reclaim: zero gain while comfortably above floor still logs plain 'OK' (not a false alarm)"
else
  bad "_safe_reclaim: expected plain 'OK' for zero-gain-but-above-floor, log tail: $(tail -3 "$LOG" 2>/dev/null | tr '\n' ';')"
fi

# Found during this bead's own pre-flight self-audit (ga-ofi307): the
# ORIGINAL one-line version of this log call already had this gap, unchanged
# — an unmeasurable post-reclaim read (df failing right after a successful
# dolt-cleanup) fell through to the exact same "OK" text as a genuine gain
# ("?GB" silently standing in for the missing number). "don't know"
# collapsing into "good news" is the same defect family this whole bead
# exists to fix, one level narrower — closed here since the block was
# already being rewritten.
_avail_gb() { echo ""; }         # after unmeasurable (simulated df failure)
_safe_reclaim 7
if grep -q "reclaim: dolt-cleanup succeeded but post-reclaim avail is UNMEASURABLE" "$LOG" 2>/dev/null; then
  ok "_safe_reclaim: unmeasurable post-reclaim avail is reported as unknown, never as calm 'OK'"
else
  bad "_safe_reclaim: expected an UNMEASURABLE line for a failed post-reclaim df read, log tail: $(tail -3 "$LOG" 2>/dev/null | tr '\n' ';')"
fi
if grep -qE '\] reclaim OK — avail 7GB -> \?GB' "$LOG" 2>/dev/null; then
  bad "_safe_reclaim: MUST NOT log the old 'reclaim OK ... ?GB' wording when the post-reclaim read failed"
else
  ok "_safe_reclaim: does not log the old '?GB'-as-OK wording for an unmeasurable read"
fi

echo ""
echo "=== _top_disk_consumers (ga-ofi307): real scan, hermetic fixture, ARG_MAX-safe on a large root ==="
# WHY: proves this reads real sizes via the real find|xargs|du pipeline
# (nothing stubbed here — the main()-level stub added later in this file is
# ONLY for main()-scenario determinism, see that stub's own comment) AND that
# the xargs-batched approach survives a root with far more entries than a
# single `du` invocation's argv could hold. MEASURED live against this host's
# actual DARWIN_USER_TEMP_DIR (~20,000 entries) while building this bead: a
# naive one-`du`-per-entry loop took 100s+ wall time from fork/exec overhead
# alone, and a single `du -sk "$dir"/*` batching every entry into one argv
# failed outright with "argument list too long" (ARG_MAX) — see this
# function's own header for both measurements. 500 entries here is enough to
# exercise the same batching path without the real test suite paying the
# full ~20,000-entry cost.
TDC_ROOT="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-tdc.XXXXXX)"
mkdir -p "$TDC_ROOT/bashdiff/big-cache-dir" "$TDC_ROOT/gobuildtmp" \
         "$TDC_ROOT/codesign_parent/X/com.google.Chrome.code_sign_clone" \
         "$TDC_ROOT/gocache_parent/go-build" "$TDC_ROOT/city/.dolt-backup"
head -c 5242880 /dev/zero > "$TDC_ROOT/bashdiff/big-cache-dir/payload" 2>/dev/null   # the one big entry this test proves gets surfaced
for i in $(seq 1 500); do mkdir -p "$TDC_ROOT/gobuildtmp/entry$i"; echo x > "$TDC_ROOT/gobuildtmp/entry$i/f"; done

# Point the four resolver functions + CITY at the fixture tree. Deliberately
# left overridden afterward, NOT restored — same precedent as this file's own
# main()-level gc_dolt_probe_robust override below: nothing between here and
# that section calls these four functions for real again (their own dedicated
# shape/fixture tests above already ran), and the main()-level section stubs
# the REAP functions that would otherwise call them wholesale.
_bash_edit_diff_root()  { echo "$TDC_ROOT/bashdiff/leaf"; }   # dirname() is the scanned root
_go_build_tmp_root()    { echo "$TDC_ROOT/gobuildtmp"; }
_code_sign_clone_root() { echo "$TDC_ROOT/codesign_parent/X/com.google.Chrome.code_sign_clone"; }
_gocache_dir()          { echo "$TDC_ROOT/gocache_parent/go-build"; }
CITY="$TDC_ROOT/city"

tdc_result="$(_top_disk_consumers 5)"

case "$tdc_result" in
  *"big-cache-dir"*) ok "_top_disk_consumers: planted 5MB fixture dir surfaced in the result" ;;
  *) bad "_top_disk_consumers: planted fixture dir missing from result — got: $(printf '%s' "$tdc_result" | tr '\n' ';')" ;;
esac
tdc_first_line="$(printf '%s\n' "$tdc_result" | head -1)"
case "$tdc_first_line" in
  *"big-cache-dir"*) ok "_top_disk_consumers: the 5MB fixture sorts FIRST (largest-first ordering, beating 500 tiny siblings)" ;;
  *) bad "_top_disk_consumers: expected the largest (5MB) fixture first, got: $tdc_first_line" ;;
esac
tdc_line_count="$(printf '%s\n' "$tdc_result" | grep -c .)"
[ "$tdc_line_count" -le 5 ] && ok "_top_disk_consumers: respects the requested n=5 cap (got $tdc_line_count lines)" || bad "_top_disk_consumers: exceeded requested n=5 cap, got $tdc_line_count lines"
rm -rf "$TDC_ROOT"

# ── _top_disk_consumers: no roots resolve/exist → empty, never a crash ──────
_bash_edit_diff_root() { echo ""; }
_go_build_tmp_root() { echo ""; }
_code_sign_clone_root() { echo ""; }
_gocache_dir() { echo ""; }
CITY="/nonexistent/path/$$/no-such-city"
tdc_empty="$(_top_disk_consumers 5)"
[ -z "$tdc_empty" ] && ok "_top_disk_consumers: no roots resolve → empty result, never a crash" || bad "_top_disk_consumers: expected empty result when no roots resolve, got: $tdc_empty"

# Restore the four resolvers + CITY to their real implementations — later
# scenarios in THIS file don't call them directly again, but leaving a global
# like CITY pointed at a deleted tmp dir is needless risk for any future
# addition between here and the main()-level section's own (deliberately
# permanent) stubs.
_bash_edit_diff_root() { echo "/private/tmp/claude-$(id -u 2>/dev/null)/bash-edit-diff"; }
_go_build_tmp_root() {
  local d
  d="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
  [ -z "$d" ] && { echo ""; return; }
  echo "${d%/}"
}
_code_sign_clone_root() {
  local t parent
  t="$(_go_build_tmp_root)"
  [ -z "$t" ] && { echo ""; return; }
  parent="$(dirname "$t")"
  echo "$parent/X/com.google.Chrome.code_sign_clone"
}
_gocache_dir() {
  local d
  d="$(command -v go >/dev/null 2>&1 && go env GOCACHE 2>/dev/null)"
  [ -n "$d" ] && { echo "$d"; return; }
  echo "$HOME/Library/Caches/go-build"
}
CITY="/Users/athos/gt/.gascity-gastown-hq"

echo ""
echo "=== disk-growth photo (ga-ond0fa): scan, photo, delta, report, gating, writers proxy ==="
# WHY: 2026-09-25 free space dived ~7GB in 45min and the guard could only log
# "avail=" — nothing said WHAT grew. These prove the pieces that answer it, on
# hermetic fixtures: the REAL find/xargs/du/lsof binaries run, but only against
# mktemp directories (and lsof only for one file this shell holds open itself);
# the state dir is redirected to a throwaway (helpers resolve $STATE_DIR at call
# time, so nothing can leak into the real $CITY/.gc/logs — see the config block).
GROW_TMP="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-growth.XXXXXX)"
STATE_DIR_BEFORE_GROWTH="$STATE_DIR"
STATE_DIR="$GROW_TMP/state"; mkdir -p "$STATE_DIR"
TAB="$(printf '\t')"
GROWTH_MIN_DELTA_MB_ORIG="$GROWTH_MIN_DELTA_MB"

# ── _growth_scan_root: real du on a fixture ────────────────────────────────────
GR="$GROW_TMP/root1"; mkdir -p "$GR/big" "$GR/small1" "$GR/small2"
head -c 5242880 /dev/zero > "$GR/big/payload"; echo x > "$GR/small1/f"; echo x > "$GR/small2/f"
scan_out="$(_growth_scan_root "$GR" 30)"
[ "$(printf '%s\n' "$scan_out" | head -1)" = "ROOT${TAB}OK${TAB}$GR" ] \
  && ok "_growth_scan_root: a fully scanned root is STATUS OK" \
  || bad "_growth_scan_root: expected 'ROOT OK $GR' first, got: $(printf '%s' "$scan_out" | head -1)"
big_kb="$(printf '%s\n' "$scan_out" | awk -F'\t' -v p="$GR/big" '$1 == "ENT" && $3 == p { print $2 }')"
case "$big_kb" in
  ''|*[!0-9]*) bad "_growth_scan_root: no ENT row for the 5MB child (got '$big_kb')" ;;
  *) [ "$big_kb" -ge 5120 ] && ok "_growth_scan_root: the 5MB child is measured (${big_kb}KB) as an ENT row" || bad "_growth_scan_root: 5MB child measured too small: ${big_kb}KB" ;;
esac
[ "$(printf '%s\n' "$scan_out" | grep -c '^ENT')" = "3" ] \
  && ok "_growth_scan_root: exactly the 3 immediate children, one ENT each" \
  || bad "_growth_scan_root: expected 3 ENT rows, got $(printf '%s\n' "$scan_out" | grep -c '^ENT')"

# ── _growth_scan_root: BSD xargs exits 1 when ANY du chunk errors (measured
#    live) — that routine case must stay OK, not PARTIAL. A fake du that fails
#    on one argument reproduces it without needing an unreadable directory. ─────
STUBBIN="$GROW_TMP/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/du" <<'STUBEOF'
#!/bin/bash
# fake du: prints a row per argument, but exits 1 as if one path was unreadable
for a in "$@"; do [ "$a" = "-sk" ] && continue; printf '100\t%s\n' "$a"; done
exit 1
STUBEOF
chmod +x "$STUBBIN/du"
routine_out="$(PATH="$STUBBIN:$PATH" _growth_scan_root "$GR" 30)"
[ "$(printf '%s\n' "$routine_out" | head -1)" = "ROOT${TAB}OK${TAB}$GR" ] \
  && ok "_growth_scan_root: du chunks exiting nonzero (permission errors — routine) still yield STATUS OK, rows kept" \
  || bad "_growth_scan_root: a nonzero du exit must not demote the root — got: $(printf '%s' "$routine_out" | head -1)"

# ── _growth_scan_root: missing root and symlinked root ─────────────────────────
[ "$(_growth_scan_root "$GROW_TMP/nope" 5)" = "ROOT${TAB}MISSING${TAB}$GROW_TMP/nope" ] \
  && ok "_growth_scan_root: a missing root is reported MISSING (not an error, not an empty OK)" \
  || bad "_growth_scan_root: missing root should read 'ROOT MISSING'"
ln -s "$GR" "$GROW_TMP/linkroot"
link_out="$(_growth_scan_root "$GROW_TMP/linkroot" 5)"
[ "$link_out" = "ROOT${TAB}SYMLINK${TAB}$GROW_TMP/linkroot" ] \
  && ok "_growth_scan_root: a symlinked root is never descended (SYMLINK, zero ENT rows — CloudStorage/FUSE hazard)" \
  || bad "_growth_scan_root: symlinked root must not be scanned, got: $link_out"

# ── _growth_scan_root: a timeout keeps the chunks that FINISHED (PARTIAL), it
#    does not lose the whole root. This is the reason for chunked+parallel du:
#    a single killed du returns zero rows (measured: ~/Library/Caches). The fake
#    du hangs on any chunk containing 'slow'. ───────────────────────────────────
cat > "$STUBBIN/du" <<'STUBEOF'
#!/bin/bash
for a in "$@"; do case "$a" in *slow*) sleep 30 ;; esac; done
for a in "$@"; do [ "$a" = "-sk" ] && continue; printf '100\t%s\n' "$a"; done
STUBEOF
GP="$GROW_TMP/rootpart"; mkdir -p "$GP/slow1"      # NOT named *slow*: the fake du hangs on any path matching it
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do mkdir -p "$GP/fast$i"; done
part_out="$(PATH="$STUBBIN:$PATH" _growth_scan_root "$GP" 3)"
[ "$(printf '%s\n' "$part_out" | head -1)" = "ROOT${TAB}PARTIAL${TAB}$GP" ] \
  && ok "_growth_scan_root: a root that hits its timeout is PARTIAL, never OK" \
  || bad "_growth_scan_root: timed-out root should be PARTIAL, got: $(printf '%s' "$part_out" | head -1)"
part_rows="$(printf '%s\n' "$part_out" | grep -c '^ENT')"
{ [ "$part_rows" -ge 8 ] && [ "$part_rows" -le 12 ]; } \
  && ok "_growth_scan_root: chunks that finished before the timeout survive ($part_rows of 13 rows kept)" \
  || bad "_growth_scan_root: expected 8-12 surviving rows after the timeout, got $part_rows"
case "$part_out" in
  *slow1*) bad "_growth_scan_root: the hung entry must not appear as a measured row" ;;
  *) ok "_growth_scan_root: the hung entry is absent — unmeasured, not fabricated as a zero" ;;
esac
rm -f "$STUBBIN/du"

# ── _disk_growth_photo: format, atomicity, budget, unwritable ──────────────────
PH="$GROW_TMP/photo1.txt"
printf '%s\n%s\n' "$GR" "$GROW_TMP/nope" | _disk_growth_photo "$PH"; ph_rc=$?
if [ "$ph_rc" = "0" ] && [ -s "$PH" ] && grep -q "^TS${TAB}[0-9]" "$PH" \
   && grep -q "^ROOT${TAB}OK${TAB}$GR" "$PH" && grep -q "^ROOT${TAB}MISSING${TAB}$GROW_TMP/nope" "$PH"; then
  ok "_disk_growth_photo: writes TS + one ROOT line per root (OK and MISSING both recorded) and returns 0"
else
  bad "_disk_growth_photo: photo malformed (rc=$ph_rc): $(head -8 "$PH" 2>/dev/null | tr '\n' '|')"
fi
[ -z "$(ls "$GROW_TMP"/photo1.txt.tmp.* 2>/dev/null)" ] \
  && ok "_disk_growth_photo: no .tmp file left behind (atomic tmp+mv)" \
  || bad "_disk_growth_photo: leftover tmp file(s): $(ls "$GROW_TMP"/photo1.txt.tmp.*)"
grep -q "^VM_DIR_KB${TAB}" "$PH" && grep -q "^VM_SWAP${TAB}" "$PH" \
  && ok "_disk_growth_photo: records VM_SWAP and VM_DIR_KB (the vm.swapusage + /System/Volumes/VM half of the bead)" \
  || bad "_disk_growth_photo: VM lines missing"

printf '%s\n' "$GR" | _disk_growth_photo "$GROW_TMP/photo-budget.txt" "" 0
if grep -q "^ROOT${TAB}SKIPPED${TAB}$GR" "$GROW_TMP/photo-budget.txt" && [ "$(grep -c '^ENT' "$GROW_TMP/photo-budget.txt")" = "0" ]; then
  ok "_disk_growth_photo: a spent budget records every remaining root SKIPPED — explicit 'not measured', no ENT rows, never a silent zero"
else
  bad "_disk_growth_photo: budget=0 should mark the root SKIPPED with no ENT rows: $(cat "$GROW_TMP/photo-budget.txt" | tr '\n' '|')"
fi

printf '%s\n' "$GR" | _disk_growth_photo "$GROW_TMP/no-such-dir/photo.txt" 2>/dev/null; bad_rc=$?
[ "$bad_rc" = "1" ] && [ ! -e "$GROW_TMP/no-such-dir" ] \
  && ok "_disk_growth_photo: an unwritable output returns 1 (the caller can retry) and creates nothing" \
  || bad "_disk_growth_photo: unwritable output should return 1, got $bad_rc"

# ── _lsof_writers_parse: canned `lsof -F pcaftsn` output ───────────────────────
# journal (pid 100) is held on TWO fds (one 'w', one 'u') = ONE row; readonly is
# mode r; a directory (DIR) and a 10-byte file are below/outside the filter; 'rev'
# lists n BEFORE s (field order within a record must not matter).
LSOF_CANNED="$(printf '%s\n' \
  p100 cdolt f4 aw tREG s3145728 n/x/journal \
  f5 ar tREG s9999999999 n/x/readonly \
  f6 au tREG s3145728 n/x/journal \
  p200 cpython f3 aw tDIR s4096 n/x/somedir \
  f7 aw tREG s10 n/x/small \
  f8 aw tREG s5242880 n/y/big \
  f9 aw tREG n/z/rev s2097152)"
wp_out="$(printf '%s\n' "$LSOF_CANNED" | _lsof_writers_parse 1)"
if [ "$(printf '%s\n' "$wp_out" | grep -c .)" = "3" ] \
   && [ "$(printf '%s\n' "$wp_out" | head -1 | awk -F'\t' '{ print $4 }')" = "/y/big" ] \
   && printf '%s\n' "$wp_out" | grep -q "^3${TAB}100${TAB}dolt${TAB}/x/journal\$" \
   && printf '%s\n' "$wp_out" | grep -q "${TAB}/z/rev\$" \
   && ! printf '%s\n' "$wp_out" | grep -q -e readonly -e somedir -e small; then
  ok "_lsof_writers_parse: only REG files held open for w/u >= min, largest first, one row per (pid,path), field order irrelevant"
else
  bad "_lsof_writers_parse: wrong rows: $(printf '%s' "$wp_out" | tr '\n' ';')"
fi

# ── _top_open_write_files: REAL lsof against a file THIS shell holds open ──────
HOLD="$GROW_TMP/held-open.bin"; head -c 3145728 /dev/zero > "$HOLD"
exec 9>>"$HOLD"
tw_out="$(_top_open_write_files 100000 1)"; tw_rc=$?    # every row: this host holds many >1MB files open, a top-10 cut could drop the fixture
exec 9>&-
if [ "$tw_rc" = "0" ] && printf '%s\n' "$tw_out" | grep -q "held-open.bin"; then
  ok "_top_open_write_files: real lsof surfaces a 3MB file held open for write (rc 0)"
else
  bad "_top_open_write_files: expected held-open.bin with rc 0, got rc=$tw_rc out=$(printf '%s' "$tw_out" | head -c 200)"
fi

# unmeasured (rc 2) must differ from measured-empty (rc 0, no rows): a fake lsof
# that prints nothing (as a failing/unavailable one does) is UNMEASURED.
STUB2="$GROW_TMP/stublsof"; mkdir -p "$STUB2"
printf '#!/bin/bash\nexit 1\n' > "$STUB2/lsof"; chmod +x "$STUB2/lsof"
PATH="$STUB2:$PATH" _top_open_write_files 10 1 >/dev/null; tw2_rc=$?
[ "$tw2_rc" = "2" ] && ok "_top_open_write_files: an lsof that yields nothing is UNMEASURED (rc 2), never 'no big writers'" || bad "_top_open_write_files: empty lsof capture should be rc 2, got $tw2_rc"
# a nonzero lsof exit WITH valid output is still valid rows (it skips what it cannot stat)
printf '#!/bin/bash\nprintf "p1\\ncx\\nf1\\naw\\ntREG\\ns5242880\\nn/q/kept\\n"\nexit 1\n' > "$STUB2/lsof"
tw3_out="$(PATH="$STUB2:$PATH" _top_open_write_files 10 1)"; tw3_rc=$?
{ [ "$tw3_rc" = "0" ] && printf '%s\n' "$tw3_out" | grep -q "/q/kept"; } \
  && ok "_top_open_write_files: a nonzero lsof exit with valid output still returns its rows" \
  || bad "_top_open_write_files: valid rows from a nonzero-exit lsof were dropped (rc=$tw3_rc out=$tw3_out)"

# ── _growth_delta: handcrafted photos covering every comparison rule ───────────
GB_BASE="$GROW_TMP/delta-base.txt"; GB_NOW="$GROW_TMP/delta-now.txt"
printf '%s\n' \
  "TS${TAB}1000" "VM_DIR_KB${TAB}1048576" \
  "ROOT${TAB}OK${TAB}/r1" \
  "ENT${TAB}1048576${TAB}/r1/grown" "ENT${TAB}2048${TAB}/r1/same" "ENT${TAB}8192${TAB}/r1/shrunk" "ENT${TAB}1024${TAB}/r1/small-growth" \
  "ROOT${TAB}OK${TAB}/r2" "ENT${TAB}4096${TAB}/r2/a" \
  "ROOT${TAB}PARTIAL${TAB}/r3" "ENT${TAB}100${TAB}/r3/x" \
  "ROOT${TAB}OK${TAB}/r4" "ENT${TAB}100${TAB}/r4/x" \
  "WRITERS${TAB}ok" "WRITER${TAB}400${TAB}77${TAB}dolt${TAB}/w/journal" "WRITER${TAB}150${TAB}88${TAB}py${TAB}/w/steady.db" > "$GB_BASE"
printf '%s\n' \
  "TS${TAB}2200" "VM_DIR_KB${TAB}3145728" \
  "ROOT${TAB}OK${TAB}/r1" \
  "ENT${TAB}6291456${TAB}/r1/grown" "ENT${TAB}2048${TAB}/r1/same" "ENT${TAB}1024${TAB}/r1/shrunk" "ENT${TAB}21504${TAB}/r1/small-growth" "ENT${TAB}307200${TAB}/r1/brandnew" \
  "ROOT${TAB}OK${TAB}/r2" "ENT${TAB}4096${TAB}/r2/a" \
  "ROOT${TAB}OK${TAB}/r3" "ENT${TAB}100${TAB}/r3/x" "ENT${TAB}900000${TAB}/r3/y" \
  "ROOT${TAB}SKIPPED${TAB}/r4" \
  "ROOT${TAB}OK${TAB}/r5" "ENT${TAB}500000${TAB}/r5/z" \
  "WRITERS${TAB}ok" "WRITER${TAB}2500${TAB}77${TAB}dolt${TAB}/w/journal" "WRITER${TAB}3000${TAB}99${TAB}build${TAB}/w/newtemp.bin" "WRITER${TAB}150${TAB}88${TAB}py${TAB}/w/steady.db" > "$GB_NOW"
gd="$(_growth_delta "$GB_BASE" "$GB_NOW" 8 50)"
gd_g() { printf '%s\n' "$gd" | awk -F'\t' '$1 == "G"'; }
[ "$(gd_g | head -1 | cut -f2,3,4,5 | tr '\t' ' ')" = "5120 6144 1024 /r1/grown" ] \
  && ok "_growth_delta: a grown entry is reported with delta/now/was in MB (5120MB: 1GB -> 6GB), largest first" \
  || bad "_growth_delta: first grower wrong: $(gd_g | head -1)"
gd_g | grep -q "${TAB}/r1/brandnew\$" && gd_g | grep "/r1/brandnew" | cut -f4 | grep -qx new \
  && ok "_growth_delta: an entry absent from an OK baseline root is 'new'" \
  || bad "_growth_delta: brandnew should be reported as 'new': $(gd_g | tr '\n' ';')"
if printf '%s\n' "$gd" | grep -q -e "/r1/same" -e "/r1/shrunk" -e "/r1/small-growth"; then
  bad "_growth_delta: unchanged / shrunk / under-threshold (+20MB < 50) entries must not be listed: $(gd_g | tr '\n' ';')"
else
  ok "_growth_delta: unchanged, shrunk and below-threshold entries are not listed"
fi
if gd_g | grep -q -e "/r3/y" -e "/r5/z"; then
  bad "_growth_delta: an entry in a root whose BASELINE was PARTIAL/absent must NOT be called new/grown (not measured then): $(gd_g | tr '\n' ';')"
else
  ok "_growth_delta: no 'new' claim about a root the baseline never fully measured (r3 PARTIAL, r5 absent)"
fi
printf '%s\n' "$gd" | grep -q "^U${TAB}/r3${TAB}baseline=PARTIAL now=OK\$" \
  && printf '%s\n' "$gd" | grep -q "^U${TAB}/r4${TAB}baseline=OK now=SKIPPED\$" \
  && printf '%s\n' "$gd" | grep -q "^U${TAB}/r5${TAB}baseline=absent now=OK\$" \
  && ok "_growth_delta: every root that could not be fully compared is reported U with its reason (PARTIAL / SKIPPED / absent)" \
  || bad "_growth_delta: missing U lines: $(printf '%s\n' "$gd" | grep '^U' | tr '\n' ';')"
printf '%s\n' "$gd" | grep -q "^V${TAB}2048${TAB}3072${TAB}1024\$" \
  && ok "_growth_delta: VM residency delta reported (V +2048MB: 1GB -> 3GB)" \
  || bad "_growth_delta: VM line wrong: $(printf '%s\n' "$gd" | grep '^V')"
gw="$(printf '%s\n' "$gd" | awk -F'\t' '$1 == "W"')"
gw_j="$(printf '%s\n' "$gw" | awk -F'\t' '$7 == "/w/journal"' | cut -f2,3,4,5,6,7 | tr '\t' ' ')"
if [ "$gw_j" = "2100 2500 400 77 dolt /w/journal" ]; then
  ok "_growth_delta: a held-open file that GREW is attributed to its holder (dolt pid 77: +2100MB) — the 'who wrote it' signal"
else
  bad "_growth_delta: writer growth wrong: $(printf '%s' "$gw" | tr '\n' ';')"
fi
printf '%s\n' "$gw" | grep -q "/w/newtemp.bin" && printf '%s\n' "$gw" | grep "/w/newtemp.bin" | cut -f4 | grep -qx absent \
  && ok "_growth_delta: a big held-open file NOT in the baseline's list is reported (marked 'absent'), the classic temp-file culprit" \
  || bad "_growth_delta: newtemp.bin should be reported as absent-from-baseline: $(printf '%s' "$gw" | tr '\n' ';')"
[ "$(printf '%s\n' "$gw" | head -1 | cut -f7)" = "/w/newtemp.bin" ] \
  && ok "_growth_delta: writer rows sort by growth, largest first (the 3000MB new temp file ahead of the +2100MB journal)" \
  || bad "_growth_delta: writer rows not sorted largest-first: $(printf '%s' "$gw" | tr '\n' ';')"
printf '%s\n' "$gw" | grep -q "steady.db" && bad "_growth_delta: an unchanged held-open file must not be listed" || ok "_growth_delta: an unchanged held-open file is not listed"

n1="$(_growth_delta "$GB_BASE" "$GB_NOW" 1 50 | awk -F'\t' '$1 == "G"' | grep -c .)"
[ "$n1" = "1" ] && ok "_growth_delta: honours the top-n cap (n=1 -> 1 grower)" || bad "_growth_delta: n=1 returned $n1 growers"

# writers not measured on EITHER side -> no W claims at all (same 'unmeasured is not zero' rule)
sed "s/^WRITERS${TAB}ok\$/WRITERS${TAB}unmeasured/" "$GB_NOW" > "$GROW_TMP/delta-now-unm.txt"
_growth_delta "$GB_BASE" "$GROW_TMP/delta-now-unm.txt" 8 50 | awk -F'\t' '$1 == "W"' | grep -q . \
  && bad "_growth_delta: no writer claims when the writers were unmeasured in one photo" \
  || ok "_growth_delta: writers unmeasured on one side -> no writer growth claimed"

[ -z "$(_growth_delta "$GROW_TMP/does-not-exist" "$GB_NOW" 8 50)" ] && [ -z "$(_growth_delta "$GB_BASE" "$GROW_TMP/does-not-exist" 8 50)" ] \
  && ok "_growth_delta: a missing baseline or photo yields empty output, rc 0 (the report says so; nothing is invented)" \
  || bad "_growth_delta: missing input should produce empty output"

# ── _growth_delta on REAL du output from synthetic directories (the bead's
#    acceptance test: 'selftest com diretórios sintéticos mostrando o delta') ────
RA="$GROW_TMP/synA"; RB="$GROW_TMP/synB"; mkdir -p "$RA/db1" "$RA/db2" "$RB/keep"
head -c 1048576 /dev/zero > "$RA/db1/f"; head -c 1048576 /dev/zero > "$RA/db2/f"; head -c 1048576 /dev/zero > "$RB/keep/f"
printf '%s\n%s\n' "$RA" "$RB" | _disk_growth_photo "$GROW_TMP/syn-base.txt"
head -c 6291456 /dev/zero > "$RA/db2/growth.bin"                      # db2 grows by 6MB
mkdir -p "$RB/newdir"; head -c 3145728 /dev/zero > "$RB/newdir/f"      # a brand-new 3MB directory
printf '%s\n%s\n' "$RA" "$RB" | _disk_growth_photo "$GROW_TMP/syn-now.txt"
syn="$(_growth_delta "$GROW_TMP/syn-base.txt" "$GROW_TMP/syn-now.txt" 8 1)"
db2_delta="$(printf '%s\n' "$syn" | awk -F'\t' -v p="$RA/db2" '$1 == "G" && $5 == p { print $2 }')"
case "$db2_delta" in
  ''|*[!0-9]*) bad "synthetic delta: db2 (+6MB) not reported as a grower: $(printf '%s' "$syn" | tr '\n' ';')" ;;
  *) [ "$db2_delta" -ge 5 ] && [ "$db2_delta" -le 7 ] && ok "synthetic delta: db2 growing 1MB -> 7MB is reported as +${db2_delta}MB from real du output" || bad "synthetic delta: db2 delta out of range: $db2_delta" ;;
esac
printf '%s\n' "$syn" | awk -F'\t' -v p="$RB/newdir" '$1 == "G" && $5 == p && $4 == "new" { f = 1 } END { exit !f }' \
  && ok "synthetic delta: a directory that did not exist at baseline is reported 'new'" \
  || bad "synthetic delta: newdir should be 'new': $(printf '%s' "$syn" | tr '\n' ';')"
if printf '%s\n' "$syn" | grep -q -e "$RA/db1" -e "$RB/keep"; then
  bad "synthetic delta: untouched db1 / keep must not be listed: $(printf '%s' "$syn" | tr '\n' ';')"
else
  ok "synthetic delta: untouched directories (db1, keep) are not listed"
fi
[ -z "$(printf '%s\n' "$syn" | grep '^U')" ] && ok "synthetic delta: two complete scans leave no NOT-FULLY-COMPARED roots" || bad "synthetic delta: unexpected U lines: $(printf '%s\n' "$syn" | grep '^U' | tr '\n' ';')"

# ── _growth_report ─────────────────────────────────────────────────────────────
rep_nb="$(_growth_report "$GROW_TMP/does-not-exist" "$GROW_TMP/syn-now.txt")"
case "$rep_nb" in
  *"No baseline photo yet"*"$RA"*) ok "_growth_report: with no baseline it says so and falls back to absolute sizes (still more than 'avail=')" ;;
  *) bad "_growth_report: no-baseline text wrong: $(printf '%s' "$rep_nb" | head -c 300)" ;;
esac
GROWTH_MIN_DELTA_MB=1
rep_syn="$(_growth_report "$GROW_TMP/syn-base.txt" "$GROW_TMP/syn-now.txt")"
GROWTH_MIN_DELTA_MB="$GROWTH_MIN_DELTA_MB_ORIG"
case "$rep_syn" in
  *"Growth since the last OK photo"*"+"*"MB  $RA/db2"*"$RB/newdir"*"was new"*) ok "_growth_report: lists the growers with +MB, path, now/was, and 'was new' for a new dir" ;;
  *) bad "_growth_report: grower lines wrong: $(printf '%s' "$rep_syn" | head -c 400)" ;;
esac
rep_none="$(_growth_report "$GROW_TMP/syn-now.txt" "$GROW_TMP/syn-now.txt")"
case "$rep_none" in
  *"none in the roots that could be compared"*) ok "_growth_report: no growth is stated outright, and points at VM / unmeasured roots as the remaining suspects" ;;
  *) bad "_growth_report: empty-growth text wrong: $(printf '%s' "$rep_none" | head -c 300)" ;;
esac
rep_hand="$(_growth_report "$GB_BASE" "$GB_NOW")"
case "$rep_hand" in
  *"20 min old"*"NOT FULLY COMPARED: /r3 (baseline=PARTIAL now=OK)"*) ok "_growth_report: shows the baseline's age (20 min) and every root that was NOT FULLY COMPARED" ;;
  *) bad "_growth_report: age / not-compared lines missing: $(printf '%s' "$rep_hand" | head -c 500)" ;;
esac
case "$rep_hand" in
  *"/System/Volumes/VM: 3072MB now, +2048MB"*) ok "_growth_report: includes the VM delta line" ;;
  *) bad "_growth_report: VM line missing" ;;
esac
case "$rep_hand" in
  *"prime suspect"*"pid=77 dolt  /w/journal"*) ok "_growth_report: held-open files that grew are listed with their holder as the prime suspect" ;;
  *) bad "_growth_report: writer-growth section missing: $(printf '%s' "$rep_hand" | head -c 700)" ;;
esac

# ── _growth_baseline_due ───────────────────────────────────────────────────────
BD_F="$GROW_TMP/bd-baseline.txt"; BD_NOW=100000
rm -f "$BD_F"; _growth_baseline_due "$BD_F" "$BD_NOW" 1800 && ok "_growth_baseline_due: no baseline file -> due" || bad "_growth_baseline_due: missing file should be due"
printf 'TS\t%s\n' "$(( BD_NOW - 10 ))" > "$BD_F"; _growth_baseline_due "$BD_F" "$BD_NOW" 1800 && bad "_growth_baseline_due: a 10s-old baseline must not be due" || ok "_growth_baseline_due: fresh baseline -> not due (rate limit holds)"
printf 'TS\t%s\n' "$(( BD_NOW - 1800 ))" > "$BD_F"; _growth_baseline_due "$BD_F" "$BD_NOW" 1800 && ok "_growth_baseline_due: exactly at the interval -> due (inclusive boundary)" || bad "_growth_baseline_due: boundary should be due"
printf 'TS\t%s\n' "$(( BD_NOW + 500 ))" > "$BD_F"; _growth_baseline_due "$BD_F" "$BD_NOW" 1800 && ok "_growth_baseline_due: a TS in the FUTURE (clock step) -> due, never frozen" || bad "_growth_baseline_due: future TS must not suppress refresh"
printf 'TS\tgarbage\n' > "$BD_F"; _growth_baseline_due "$BD_F" "$BD_NOW" 1800 && ok "_growth_baseline_due: garbled TS -> due (fail-open)" || bad "_growth_baseline_due: garbled TS should be due"
printf 'ROOT\tOK\t/x\n' > "$BD_F"; _growth_baseline_due "$BD_F" "$BD_NOW" 1800 && ok "_growth_baseline_due: a file without a TS line -> due" || bad "_growth_baseline_due: TS-less file should be due"

# ── _growth_should_photo: episode gating table ─────────────────────────────────
sp_check() { # level class expect(0=photo,1=no)
  _growth_should_photo "$1" "$2"; local rc=$?
  [ "$rc" = "$3" ] && ok "_growth_should_photo: level='$1' class=$2 -> $( [ "$3" = 0 ] && echo photo || echo skip )" || bad "_growth_should_photo: level='$1' class=$2 expected rc=$3, got $rc"
}
sp_check "" WARN 0; sp_check "" CRITICAL 0
sp_check WARN WARN 1; sp_check WARN CRITICAL 0
sp_check CRITICAL CRITICAL 1; sp_check CRITICAL WARN 1
sp_check "" NONE 1; sp_check CRITICAL UNKNOWN 1; sp_check garbage WARN 0

# ── episode lifecycle: real _disk_growth_photo/_growth_delta on fixtures, with
#    the writers lsof and the root list swapped for hermetic stand-ins ───────────
eval "$(declare -f _top_open_write_files | sed '1s/^_top_open_write_files/_real_top_open_write_files/')"
eval "$(declare -f _growth_roots | sed '1s/^_growth_roots/_real_growth_roots/')"
eval "$(declare -f _disk_growth_photo | sed '1s/^_disk_growth_photo/_real_disk_growth_photo/')"
WRITERS_STUB_RC=0
_top_open_write_files() { [ "$WRITERS_STUB_RC" = "0" ] && printf '2158\t417\tfileproviderd\t/x/db\n'; return "$WRITERS_STUB_RC"; }
_growth_roots() { printf '%s\n%s\n' "$RA" "$RB"; }
GROWTH_MIN_DELTA_MB=1
EP_NOW="$(date +%s)"
: > "$LOG"

# baseline: taken when due, then rate-limited, then refreshed when old, and off when disabled
BASEF="$(_growth_baseline_file)"; rm -f "$BASEF"
_growth_baseline_refresh "$EP_NOW"
if [ -s "$BASEF" ] && grep -q "^TS${TAB}[0-9]" "$BASEF" && grep -q "growth baseline photo refreshed" "$LOG"; then
  ok "_growth_baseline_refresh: takes the first baseline when none exists and logs it"
else
  bad "_growth_baseline_refresh: no baseline written / logged: $(tail -3 "$LOG" | tr '\n' '|')"
fi
grep -q "^WRITERS${TAB}ok" "$BASEF" && ok "_growth_baseline_refresh: the baseline records writers too (so the diff can attribute growth to a holder)" || bad "_growth_baseline_refresh: baseline missing WRITERS section"
echo "# marker" >> "$BASEF"
_growth_baseline_refresh "$EP_NOW"
grep -q '^# marker' "$BASEF" && ok "_growth_baseline_refresh: a fresh baseline is left alone inside the interval (rate limit: no scan)" || bad "_growth_baseline_refresh: rescanned inside the interval"
sed "s/^TS${TAB}.*/TS${TAB}$(( EP_NOW - 3600 ))/" "$BASEF" > "$BASEF.x" && mv "$BASEF.x" "$BASEF"
_growth_baseline_refresh "$EP_NOW"
if grep -q '^# marker' "$BASEF"; then bad "_growth_baseline_refresh: an hour-old baseline should have been refreshed"; else ok "_growth_baseline_refresh: an old baseline is refreshed (atomically replaced)"; fi
GROWTH_PHOTO_ENABLED=0
echo "# marker2" >> "$BASEF"; sed "s/^TS${TAB}.*/TS${TAB}$(( EP_NOW - 7200 ))/" "$BASEF" > "$BASEF.x" && mv "$BASEF.x" "$BASEF"
_growth_baseline_refresh "$EP_NOW"; _growth_episode_photo WARN 6
if grep -q '^# marker2' "$BASEF" && [ -z "$(ls "$STATE_DIR"/disk-growth-*.txt 2>/dev/null)" ]; then
  ok "GROWTH_PHOTO_ENABLED=0: neither the baseline refresh nor the episode photo runs"
else
  bad "GROWTH_PHOTO_ENABLED=0 did not disable the photo feature"
fi
GROWTH_PHOTO_ENABLED=1
_growth_baseline_refresh "$EP_NOW"     # old TS again -> fresh baseline, taken BEFORE the growth below
BASE_SUM_BEFORE="$(cksum < "$BASEF")"

# growth happens; first WARN cycle photographs, later WARN cycles of the episode do not
head -c 8388608 /dev/zero > "$RA/db1/g.bin"
: > "$LOG"
_growth_episode_photo WARN 6
EPF="$(_growth_episode_file)"
PHOTOS="$(ls -1 "$STATE_DIR"/disk-growth-*.txt 2>/dev/null)"
if [ "$(printf '%s\n' "$PHOTOS" | grep -c .)" = "1" ] && [ "$(sed -n 1p "$EPF")" = "WARN" ] && [ "$(sed -n 2p "$EPF")" = "$PHOTOS" ]; then
  ok "_growth_episode_photo: first WARN cycle writes disk-growth-<ts>.txt and records level+path in the episode file"
else
  bad "_growth_episode_photo: first WARN photo/episode state wrong (photos=$PHOTOS episode=$(tr '\n' '|' < "$EPF" 2>/dev/null))"
fi
if grep -q "BEFORE the reclaim levers run" "$LOG" && grep -q "disk-growth photo written" "$LOG" && grep -q "db1" "$LOG"; then
  ok "_growth_episode_photo: logs that it ran before the reclaim levers, where the file is, and the top growers (db1)"
else
  bad "_growth_episode_photo: log missing lines: $(tr '\n' '|' < "$LOG" | head -c 400)"
fi
grep -q "^# ==== disk-growth report" "$PHOTOS" && grep -q "db1" "$PHOTOS" && grep -q "fileproviderd" "$PHOTOS" \
  && ok "_growth_episode_photo: the file carries the raw photo AND the human report (growers + writers section)" \
  || bad "_growth_episode_photo: report section missing from $PHOTOS"
[ "$(cksum < "$BASEF")" = "$BASE_SUM_BEFORE" ] && ok "_growth_episode_photo: leaves the baseline untouched (the baseline stays the LAST OK photo)" || bad "_growth_episode_photo: modified the baseline"
_growth_episode_photo WARN 6
[ "$(ls -1 "$STATE_DIR"/disk-growth-*.txt | grep -c .)" = "1" ] && ok "_growth_episode_photo: a second WARN cycle in the same episode is a no-op (rate-limited to one photo per level)" || bad "_growth_episode_photo: re-photographed within the same WARN level"
sleep 1                                  # distinct <ts> stamp for the CRITICAL photo
_growth_episode_photo CRITICAL 2
if [ "$(ls -1 "$STATE_DIR"/disk-growth-*.txt | grep -c .)" = "2" ] && [ "$(sed -n 1p "$EPF")" = "CRITICAL" ] && grep -q "class=CRITICAL" "$(sed -n 2p "$EPF")"; then
  ok "_growth_episode_photo: the first CRITICAL cycle photographs AGAIN (a fill that began at WARN is worse by then)"
else
  bad "_growth_episode_photo: WARN->CRITICAL should add a second photo (episode=$(tr '\n' '|' < "$EPF"))"
fi
_growth_episode_photo CRITICAL 2
[ "$(ls -1 "$STATE_DIR"/disk-growth-*.txt | grep -c .)" = "2" ] && ok "_growth_episode_photo: later CRITICAL cycles of the episode do not photograph again" || bad "_growth_episode_photo: re-photographed at the same CRITICAL level"

# the Mayor-mail paragraph cites THIS episode's latest photo, even from a later cycle
mt="$(_growth_mail_text)"
case "$mt" in
  *"Photo file: $(sed -n 2p "$EPF")"*"db1"*) ok "_growth_mail_text: cites the episode's photo path and its growers" ;;
  *) bad "_growth_mail_text: wrong: $(printf '%s' "$mt" | head -c 300)" ;;
esac

# an episode ends when the disk recovers: fresh photo next time, and the mail text says there is none
_growth_clear_episode
case "$(_growth_mail_text)" in
  *"no disk-growth photo recorded for this episode"*) ok "_growth_mail_text: with no photo this episode it says so explicitly (never silence, never a stale photo)" ;;
  *) bad "_growth_mail_text: expected the explicit no-photo statement" ;;
esac
sleep 1
_growth_episode_photo WARN 6
[ "$(ls -1 "$STATE_DIR"/disk-growth-*.txt | grep -c .)" = "3" ] && ok "_growth_clear_episode: after recovery the next WARN earns a fresh photo" || bad "_growth_clear_episode: next episode should re-photograph"

# a failed photo is NOT recorded as taken, so the next cycle retries
_growth_clear_episode
_disk_growth_photo() { return 1; }
: > "$LOG"
_growth_episode_photo WARN 6
if [ ! -e "$EPF" ] && grep -q "could not be written" "$LOG"; then
  ok "_growth_episode_photo: a photo that could not be written logs a WARN and does NOT mark the episode photographed (retried next cycle)"
else
  bad "_growth_episode_photo: failed photo must not be recorded (episode file exists=$([ -e "$EPF" ] && echo yes || echo no))"
fi
eval "$(declare -f _real_disk_growth_photo | sed '1s/^_real_disk_growth_photo/_disk_growth_photo/')"

# retention: only the newest N of OUR files go; foreign files are never touched
GROWTH_KEEP_PHOTOS_ORIG="$GROWTH_KEEP_PHOTOS"; GROWTH_KEEP_PHOTOS=2
rm -f "$STATE_DIR"/disk-growth-*.txt
for i in 1 2 3 4; do : > "$STATE_DIR/disk-growth-2020010$i-000000.txt"; done
: > "$STATE_DIR/unrelated.txt"; : > "$STATE_DIR/.dolt-disk-floor-guard.last-notify"
_growth_prune_photos
left="$(ls -1 "$STATE_DIR"/disk-growth-*.txt | sed 's|.*/||' | tr '\n' ' ')"
if [ "$left" = "disk-growth-20200103-000000.txt disk-growth-20200104-000000.txt " ] && [ -e "$STATE_DIR/unrelated.txt" ] && [ -e "$STATE_DIR/.dolt-disk-floor-guard.last-notify" ]; then
  ok "_growth_prune_photos: keeps only the newest N photos; unrelated state files are never touched"
else
  bad "_growth_prune_photos: wrong survivors: $left"
fi
GROWTH_KEEP_PHOTOS="$GROWTH_KEEP_PHOTOS_ORIG"

# restore everything this section swapped, so later sections see the real functions
eval "$(declare -f _real_top_open_write_files | sed '1s/^_real_top_open_write_files/_top_open_write_files/')"
eval "$(declare -f _real_growth_roots | sed '1s/^_real_growth_roots/_growth_roots/')"
GROWTH_MIN_DELTA_MB="$GROWTH_MIN_DELTA_MB_ORIG"
STATE_DIR="$STATE_DIR_BEFORE_GROWTH"
rm -rf "$GROW_TMP"

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
echo "=== _reap_dead_scratch: CRITICAL-pressure plumbing (ga-rjhfz) ==="
# scratchpad-reaper.sh's own size-escape gate (independently selftested)
# only activates when it sees SCRATCHPAD_REAPER_PRESSURE=CRITICAL.
# _reap_dead_scratch is the ONLY place that can set it — main() passes
# was_critical (1 iff this cycle was CRITICAL at any point, pre- or
# post-reclaim) as $1. Same hermetic fake-CITY/capture-file technique as the
# PROD=1 wiring test above: never touches the real reaper.
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/scratchpad-reaper.sh" <<EOF
#!/bin/bash
echo "PRESSURE=\${SCRATCHPAD_REAPER_PRESSURE:-unset}" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/scratchpad-reaper.sh"

REAL_CITY="$CITY"
CITY="$FAKE_CITY"
_reap_dead_scratch 1
CITY="$REAL_CITY"
if [ -f "$CAPTURE_FILE" ] && grep -qx "PRESSURE=CRITICAL" "$CAPTURE_FILE"; then
  ok "_reap_dead_scratch(was_critical=1): sets SCRATCHPAD_REAPER_PRESSURE=CRITICAL (size-escape enabled)"
else
  bad "_reap_dead_scratch(was_critical=1): did NOT set SCRATCHPAD_REAPER_PRESSURE=CRITICAL (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi

CITY="$FAKE_CITY"
_reap_dead_scratch 0
CITY="$REAL_CITY"
if [ -f "$CAPTURE_FILE" ] && grep -qx "PRESSURE=unset" "$CAPTURE_FILE"; then
  ok "_reap_dead_scratch(was_critical=0): leaves SCRATCHPAD_REAPER_PRESSURE unset (non-critical cycle, no escape)"
else
  bad "_reap_dead_scratch(was_critical=0): should NOT set SCRATCHPAD_REAPER_PRESSURE (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi

CITY="$FAKE_CITY"
_reap_dead_scratch   # no arg at all — must default the same as explicit 0 (backward compatible with the PROD=1 test above, which calls it bare)
CITY="$REAL_CITY"
if [ -f "$CAPTURE_FILE" ] && grep -qx "PRESSURE=unset" "$CAPTURE_FILE"; then
  ok "_reap_dead_scratch(no arg): defaults was_critical to non-critical (backward compatible)"
else
  bad "_reap_dead_scratch(no arg): should default to no pressure escape (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_dead_transcripts: production sentinel wiring (ga-lfj05) ==="
# Same proof as _reap_dead_scratch above, for the sibling lever: transcript-
# reaper.sh's own header names _reap_dead_transcripts as the ONLY allowed
# setter of TRANSCRIPT_REAPER_PROD=1. Hermetic: CITY is a plain global (not
# readonly), reassigned here to a disposable tmp dir containing a FAKE
# transcript-reaper.sh that only records what env it received — never
# touches the real transcript-reaper.sh, no real `gc session list`, no real
# deletion.
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city2.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/transcript-reaper.sh" <<EOF
#!/bin/bash
echo "PROD=\${TRANSCRIPT_REAPER_PROD:-unset}" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/transcript-reaper.sh"

REAL_CITY="$CITY"
CITY="$FAKE_CITY"
_reap_dead_transcripts
CITY="$REAL_CITY"

if [ -f "$CAPTURE_FILE" ] && grep -qx "PROD=1" "$CAPTURE_FILE"; then
  ok "_reap_dead_transcripts: sets TRANSCRIPT_REAPER_PROD=1 when invoking the real reaper (production opt-in wired)"
else
  bad "_reap_dead_transcripts: did NOT set TRANSCRIPT_REAPER_PROD=1 — real launchd path would silently dry-run forever (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_dead_transcripts: TIMEOUT and FAILURE must not log the same thing ==="
# WHY: measured 2026-08-01 in the live guard log — 5 runs, 5 timeouts, ZERO
# successes, each lasting exactly ~60s against the old `timeout 60`. Every one
# logged the generic "transcript-reap FAILED or aborted (nonzero exit)", which
# reads as "tried and could not free space" when the truth was "was killed
# before it could try". A full pass measures ~39s on this host, and the
# liveness call it makes first stretches 1.3s -> 10-20s exactly when Dolt is
# warm — i.e. exactly when disk pressure triggers this path. Collapsing the two
# outcomes hid a completely broken emergency disk-reclaim (root-class:error-vs-empty).
FAKE_CITY_T="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city3.XXXXXX)"
mkdir -p "$FAKE_CITY_T/scripts"
REAL_CITY="$CITY"; REAL_LOG="$LOG"

# (a) reaper that OUTLIVES the bound -> must say TIMED OUT, not FAILED
cat > "$FAKE_CITY_T/scripts/transcript-reaper.sh" <<'EOF'
#!/bin/bash
sleep 5
exit 0
EOF
chmod +x "$FAKE_CITY_T/scripts/transcript-reaper.sh"
LOG="$FAKE_CITY_T/timeout.log"; : > "$LOG"
CITY="$FAKE_CITY_T"; TRANSCRIPT_REAP_TIMEOUT_SECS=1 _reap_dead_transcripts; CITY="$REAL_CITY"
if grep -q "TIMED OUT" "$LOG" 2>/dev/null; then
  ok "_reap_dead_transcripts: a run killed by the bound logs TIMED OUT (reclaim did not complete)"
else
  bad "_reap_dead_transcripts: bound-kill did NOT log TIMED OUT — got: $(tr '\n' ';' < "$LOG" | cut -c1-140)"
fi
if grep -qE "FAILED after" "$LOG" 2>/dev/null; then
  bad "_reap_dead_transcripts: a TIMEOUT was also reported as FAILED — the two are still conflated"
else
  ok "_reap_dead_transcripts: a TIMEOUT is not also reported as a genuine failure"
fi

# (b) reaper that exits nonzero QUICKLY -> must say FAILED, not TIMED OUT
cat > "$FAKE_CITY_T/scripts/transcript-reaper.sh" <<'EOF'
#!/bin/bash
exit 3
EOF
chmod +x "$FAKE_CITY_T/scripts/transcript-reaper.sh"
LOG="$FAKE_CITY_T/failed.log"; : > "$LOG"
CITY="$FAKE_CITY_T"; TRANSCRIPT_REAP_TIMEOUT_SECS=30 _reap_dead_transcripts; CITY="$REAL_CITY"
if grep -qE "FAILED after" "$LOG" 2>/dev/null && ! grep -q "TIMED OUT" "$LOG" 2>/dev/null; then
  ok "_reap_dead_transcripts: a genuine nonzero exit logs FAILED (not TIMED OUT) — no blind spot introduced"
else
  bad "_reap_dead_transcripts: genuine failure misreported — got: $(tr '\n' ';' < "$LOG" | cut -c1-140)"
fi

# (c) the real default bound must cover the measured ~39s pass with margin
LOG="$FAKE_CITY_T/default.log"; : > "$LOG"
cat > "$FAKE_CITY_T/scripts/transcript-reaper.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FAKE_CITY_T/scripts/transcript-reaper.sh"
CITY="$FAKE_CITY_T"; unset TRANSCRIPT_REAP_TIMEOUT_SECS; _reap_dead_transcripts; CITY="$REAL_CITY"
if grep -q "bound=300s" "$LOG" 2>/dev/null; then
  ok "_reap_dead_transcripts: default bound is 300s — covers the measured ~39s pass even when Dolt is warm"
else
  bad "_reap_dead_transcripts: default bound is not 300s — got: $(tr '\n' ';' < "$LOG" | cut -c1-140)"
fi
LOG="$REAL_LOG"
rm -rf "$FAKE_CITY_T"

echo ""
echo "=== _reap_hf_cache: production sentinel wiring (wa-9eh0v) ==="
# Same hermetic fake-CITY/capture-file technique as the other levers above:
# CITY reassigned to a disposable tmp dir containing a FAKE
# .gc/recall-venv/bin/python3 that only records the env it received — never
# touches the real recall-venv, no real huggingface_hub import, no real
# cache deletion. _reap_hf_cache is the REAL caller hf_cache_reap.py's own
# header names as the one allowed to set HF_CACHE_REAP_PROD=1 — this proves
# it actually does, when the cycle was CRITICAL (was_critical=1).
FAKE_CITY_H="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city.XXXXXX)"
mkdir -p "$FAKE_CITY_H/scripts" "$FAKE_CITY_H/.gc/recall-venv/bin"
touch "$FAKE_CITY_H/scripts/hf_cache_reap.py"
CAPTURE_FILE="$FAKE_CITY_H/capture.txt"
cat > "$FAKE_CITY_H/.gc/recall-venv/bin/python3" <<EOF
#!/bin/bash
echo "PROD=\${HF_CACHE_REAP_PROD:-unset} ARG1=\${1:-none}" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY_H/.gc/recall-venv/bin/python3"

REAL_CITY="$CITY"
CITY="$FAKE_CITY_H"
_reap_hf_cache 1
CITY="$REAL_CITY"

if [ -f "$CAPTURE_FILE" ] && grep -q "^PROD=1 " "$CAPTURE_FILE"; then
  ok "_reap_hf_cache(was_critical=1): sets HF_CACHE_REAP_PROD=1 when invoking the real reaper (production opt-in wired)"
else
  bad "_reap_hf_cache(was_critical=1): did NOT set HF_CACHE_REAP_PROD=1 — real launchd path would silently dry-run forever (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
if [ -f "$CAPTURE_FILE" ] && grep -q "ARG1=$FAKE_CITY_H/scripts/hf_cache_reap.py" "$CAPTURE_FILE"; then
  ok "_reap_hf_cache(was_critical=1): invokes the venv python3 with the script's own path as argv[1]"
else
  bad "_reap_hf_cache(was_critical=1): did not pass the expected script path (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
rm -rf "$FAKE_CITY_H"

echo ""
echo "=== _reap_hf_cache: CRITICAL-only gating (wa-9eh0v) ==="
# UNLIKE _reap_dead_scratch/_reap_dead_transcripts/_reap_growing_logs (which
# all run at WARN too), this lever has a real recurring cost (next `recall`
# call pays a re-download) and must be a strict no-op below CRITICAL — the
# capture file must never even be created.
FAKE_CITY_H="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city.XXXXXX)"
mkdir -p "$FAKE_CITY_H/scripts" "$FAKE_CITY_H/.gc/recall-venv/bin"
touch "$FAKE_CITY_H/scripts/hf_cache_reap.py"
CAPTURE_FILE="$FAKE_CITY_H/capture.txt"
cat > "$FAKE_CITY_H/.gc/recall-venv/bin/python3" <<EOF
#!/bin/bash
echo "CALLED" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY_H/.gc/recall-venv/bin/python3"

REAL_CITY="$CITY"
CITY="$FAKE_CITY_H"
_reap_hf_cache 0
if [ ! -f "$CAPTURE_FILE" ]; then
  ok "_reap_hf_cache(was_critical=0): never invokes the venv (WARN-tier is a strict no-op — cost is CRITICAL-only)"
else
  bad "_reap_hf_cache(was_critical=0): invoked the venv when it should have skipped (got: $(cat "$CAPTURE_FILE")"
fi

_reap_hf_cache   # no arg at all — must default the same as explicit 0
if [ ! -f "$CAPTURE_FILE" ]; then
  ok "_reap_hf_cache(no arg): defaults was_critical to non-critical (backward-compatible no-op)"
else
  bad "_reap_hf_cache(no arg): should default to skip, invoked the venv instead (got: $(cat "$CAPTURE_FILE")"
fi
CITY="$REAL_CITY"
rm -rf "$FAKE_CITY_H"

echo ""
echo "=== _reap_hf_cache: guard-level ENABLED kill switch (wa-9eh0v) ==="
FAKE_CITY_H="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city.XXXXXX)"
mkdir -p "$FAKE_CITY_H/scripts" "$FAKE_CITY_H/.gc/recall-venv/bin"
touch "$FAKE_CITY_H/scripts/hf_cache_reap.py"
CAPTURE_FILE="$FAKE_CITY_H/capture.txt"
cat > "$FAKE_CITY_H/.gc/recall-venv/bin/python3" <<EOF
#!/bin/bash
echo "CALLED" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY_H/.gc/recall-venv/bin/python3"

REAL_CITY="$CITY"; CITY="$FAKE_CITY_H"
REAL_ENABLED="$ENABLED"; ENABLED=0
_reap_hf_cache 1
ENABLED="$REAL_ENABLED"; CITY="$REAL_CITY"
if [ ! -f "$CAPTURE_FILE" ]; then
  ok "_reap_hf_cache: ENABLED=0 skips this lever too (not just the other four)"
else
  bad "_reap_hf_cache: ENABLED=0 did not prevent invocation (got: $(cat "$CAPTURE_FILE")"
fi
rm -rf "$FAKE_CITY_H"

echo ""
echo "=== _reap_hf_cache: missing script/venv degrades to SKIP, never errors (wa-9eh0v) ==="
# A fresh checkout without the recall-venv built yet (or a future refactor
# that moves hf_cache_reap.py) must never crash the guard cycle — same
# defensive contract as _reap_dead_scratch's [ ! -f "$reaper" ] check.
FAKE_CITY_H="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city.XXXXXX)"
REAL_CITY="$CITY"; CITY="$FAKE_CITY_H"
if _reap_hf_cache 1; then
  ok "_reap_hf_cache: missing script AND missing venv — returns cleanly (no crash)"
else
  bad "_reap_hf_cache: missing script/venv should still return 0, got nonzero"
fi
CITY="$REAL_CITY"
rm -rf "$FAKE_CITY_H"

echo ""
echo "=== _reap_growing_logs: production sentinel wiring (ga-dnc2m) ==="
# Same proof as _reap_dead_scratch/_reap_dead_transcripts above, for the 4th
# lever: log-reaper.sh's own header names _reap_growing_logs as the ONLY
# allowed setter of LOG_REAPER_PROD=1. Hermetic: CITY is a plain global (not
# readonly), reassigned here to a disposable tmp dir containing a FAKE
# log-reaper.sh that only records what env it received — never touches the
# real log-reaper.sh, no real file truncation.
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city4.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/log-reaper.sh" <<EOF
#!/bin/bash
echo "PROD=\${LOG_REAPER_PROD:-unset}" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/log-reaper.sh"

REAL_CITY="$CITY"
CITY="$FAKE_CITY"
_reap_growing_logs
CITY="$REAL_CITY"

if [ -f "$CAPTURE_FILE" ] && grep -qx "PROD=1" "$CAPTURE_FILE"; then
  ok "_reap_growing_logs: sets LOG_REAPER_PROD=1 when invoking the real reaper (production opt-in wired)"
else
  bad "_reap_growing_logs: did NOT set LOG_REAPER_PROD=1 — real launchd path would silently dry-run forever (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_growing_logs: guard-level ENABLED kill switch (ga-dnc2m) ==="
# DOLT_DISK_FLOOR_GUARD_ENABLED=0 must skip this lever too, same as the other
# three — the header's "Kill switch" note says ALL FOUR reclaim actions.
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city5.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/log-reaper.sh" <<EOF
#!/bin/bash
echo "CALLED" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/log-reaper.sh"

REAL_CITY="$CITY"
CITY="$FAKE_CITY"
ENABLED=0
_reap_growing_logs
# shellcheck disable=SC2034  # read by every _reap_* call and main() in later scenarios below
ENABLED=1
CITY="$REAL_CITY"
[ -f "$CAPTURE_FILE" ] && bad "_reap_growing_logs: ran the real log-reaper.sh despite ENABLED=0" || ok "_reap_growing_logs: ENABLED=0 skips this lever too (not just the other three)"
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_backup_residue: production sentinel wiring (ga-8f1uh0) ==="
# Same proof as _reap_growing_logs above, for the ninth lever: dolt-backup-
# residue-reclaim.sh's own header names _reap_backup_residue as the ONLY
# allowed setter of DOLT_BACKUP_RESIDUE_RECLAIM_PROD=1. Hermetic: CITY is a
# plain global, reassigned here to a disposable tmp dir containing a FAKE
# dolt-backup-residue-reclaim.sh that only records what env it received —
# never touches the real script, no real AWS call, no real deletion.
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city6.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/dolt-backup-residue-reclaim.sh" <<EOF
#!/bin/bash
echo "PROD=\${DOLT_BACKUP_RESIDUE_RECLAIM_PROD:-unset}" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/dolt-backup-residue-reclaim.sh"

REAL_CITY="$CITY"
CITY="$FAKE_CITY"
_reap_backup_residue
CITY="$REAL_CITY"

if [ -f "$CAPTURE_FILE" ] && grep -qx "PROD=1" "$CAPTURE_FILE"; then
  ok "_reap_backup_residue: sets DOLT_BACKUP_RESIDUE_RECLAIM_PROD=1 when invoking the real reclaimer (production opt-in wired)"
else
  bad "_reap_backup_residue: did NOT set DOLT_BACKUP_RESIDUE_RECLAIM_PROD=1 — real launchd path would silently dry-run forever (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_backup_residue: guard-level ENABLED kill switch (ga-8f1uh0) ==="
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city7.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/dolt-backup-residue-reclaim.sh" <<EOF
#!/bin/bash
echo "CALLED" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/dolt-backup-residue-reclaim.sh"

REAL_CITY="$CITY"
CITY="$FAKE_CITY"
ENABLED=0
_reap_backup_residue
# shellcheck disable=SC2034  # read by every _reap_* call and main() in later scenarios below
ENABLED=1
CITY="$REAL_CITY"
[ -f "$CAPTURE_FILE" ] && bad "_reap_backup_residue: ran the real reclaimer despite ENABLED=0" || ok "_reap_backup_residue: ENABLED=0 skips this lever too"
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_backup_residue: missing script degrades to SKIP, never errors (ga-8f1uh0) ==="
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city8.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
REAL_CITY="$CITY"; CITY="$FAKE_CITY"
if _reap_backup_residue; then
  ok "_reap_backup_residue: missing script — returns cleanly (no crash)"
else
  bad "_reap_backup_residue: missing script should still return 0, got nonzero"
fi
CITY="$REAL_CITY"
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_bloated_backup_staging: invokes reseed for an eligible db, CRITICAL only (ga-74tts6) ==="
# Hermetic: CITY/DOLTDIR/STATE_RESEED_TRIGGER_DIR redirected to a disposable
# tmp tree containing a FAKE dolt-backup-reseed.sh that only records the db
# name it was invoked with — never the real script, no real S3/dolt call.
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city9.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts" "$FAKE_CITY/.dolt-backup/hq" "$FAKE_CITY/.beads/dolt/hq"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/dolt-backup-reseed.sh" <<EOF
#!/bin/bash
echo "CALLED_WITH=\$1" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/dolt-backup-reseed.sh"

REAL_CITY="$CITY"; REAL_DOLTDIR="$DOLTDIR"; REAL_STATE_RESEED_TRIGGER_DIR="$STATE_RESEED_TRIGGER_DIR"
CITY="$FAKE_CITY"; DOLTDIR="$FAKE_CITY/.beads/dolt"; STATE_RESEED_TRIGGER_DIR="$FAKE_CITY/state-reseed"
_reap_bloated_backup_staging 1
CITY="$REAL_CITY"; DOLTDIR="$REAL_DOLTDIR"; STATE_RESEED_TRIGGER_DIR="$REAL_STATE_RESEED_TRIGGER_DIR"

if [ -f "$CAPTURE_FILE" ] && grep -qx "CALLED_WITH=hq" "$CAPTURE_FILE"; then
  ok "_reap_bloated_backup_staging(was_critical=1): invokes dolt-backup-reseed.sh with the eligible db name"
else
  bad "_reap_bloated_backup_staging(was_critical=1): did not invoke reseed as expected (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_bloated_backup_staging: CRITICAL-only gating (ga-74tts6) ==="
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city10.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts" "$FAKE_CITY/.dolt-backup/hq" "$FAKE_CITY/.beads/dolt/hq"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/dolt-backup-reseed.sh" <<EOF
#!/bin/bash
echo "CALLED" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/dolt-backup-reseed.sh"

REAL_CITY="$CITY"; REAL_DOLTDIR="$DOLTDIR"; REAL_STATE_RESEED_TRIGGER_DIR="$STATE_RESEED_TRIGGER_DIR"
CITY="$FAKE_CITY"; DOLTDIR="$FAKE_CITY/.beads/dolt"; STATE_RESEED_TRIGGER_DIR="$FAKE_CITY/state-reseed"
_reap_bloated_backup_staging 0
_reap_bloated_backup_staging
CITY="$REAL_CITY"; DOLTDIR="$REAL_DOLTDIR"; STATE_RESEED_TRIGGER_DIR="$REAL_STATE_RESEED_TRIGGER_DIR"

if [ -f "$CAPTURE_FILE" ]; then
  bad "_reap_bloated_backup_staging: invoked reseed on a non-CRITICAL cycle (was_critical=0 and no-arg) — should be a strict no-op"
else
  ok "_reap_bloated_backup_staging: was_critical=0 and no-arg (default) both correctly skip — CRITICAL-only cost is real (real sync/restore I/O)"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_bloated_backup_staging: guard-level ENABLED kill switch (ga-74tts6) ==="
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city11.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts" "$FAKE_CITY/.dolt-backup/hq" "$FAKE_CITY/.beads/dolt/hq"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/dolt-backup-reseed.sh" <<EOF
#!/bin/bash
echo "CALLED" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/dolt-backup-reseed.sh"

REAL_CITY="$CITY"; REAL_DOLTDIR="$DOLTDIR"; REAL_STATE_RESEED_TRIGGER_DIR="$STATE_RESEED_TRIGGER_DIR"
CITY="$FAKE_CITY"; DOLTDIR="$FAKE_CITY/.beads/dolt"; STATE_RESEED_TRIGGER_DIR="$FAKE_CITY/state-reseed"
ENABLED=0
_reap_bloated_backup_staging 1
# shellcheck disable=SC2034  # read by every _reap_* call and main() in later scenarios below
ENABLED=1
CITY="$REAL_CITY"; DOLTDIR="$REAL_DOLTDIR"; STATE_RESEED_TRIGGER_DIR="$REAL_STATE_RESEED_TRIGGER_DIR"
[ -f "$CAPTURE_FILE" ] && bad "_reap_bloated_backup_staging: ran the real reseed script despite ENABLED=0" || ok "_reap_bloated_backup_staging: ENABLED=0 skips this lever too"
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_bloated_backup_staging: missing script degrades to SKIP, never errors (ga-74tts6) ==="
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city12.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts" "$FAKE_CITY/.dolt-backup/hq" "$FAKE_CITY/.beads/dolt/hq"
REAL_CITY="$CITY"; REAL_DOLTDIR="$DOLTDIR"
CITY="$FAKE_CITY"; DOLTDIR="$FAKE_CITY/.beads/dolt"
if _reap_bloated_backup_staging 1; then
  ok "_reap_bloated_backup_staging: missing reseed script — returns cleanly (no crash)"
else
  bad "_reap_bloated_backup_staging: missing script should still return 0, got nonzero"
fi
CITY="$REAL_CITY"; DOLTDIR="$REAL_DOLTDIR"
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_bloated_backup_staging: skips a db with .old residue, still processes another (ga-74tts6) ==="
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city13.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts" "$FAKE_CITY/.dolt-backup/hq" "$FAKE_CITY/.dolt-backup/hq.old" "$FAKE_CITY/.dolt-backup/lexbh" "$FAKE_CITY/.beads/dolt/hq" "$FAKE_CITY/.beads/dolt/lexbh"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/dolt-backup-reseed.sh" <<EOF
#!/bin/bash
echo "CALLED_WITH=\$1" >> "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/dolt-backup-reseed.sh"

REAL_CITY="$CITY"; REAL_DOLTDIR="$DOLTDIR"; REAL_STATE_RESEED_TRIGGER_DIR="$STATE_RESEED_TRIGGER_DIR"
CITY="$FAKE_CITY"; DOLTDIR="$FAKE_CITY/.beads/dolt"; STATE_RESEED_TRIGGER_DIR="$FAKE_CITY/state-reseed"
_reap_bloated_backup_staging 1
CITY="$REAL_CITY"; DOLTDIR="$REAL_DOLTDIR"; STATE_RESEED_TRIGGER_DIR="$REAL_STATE_RESEED_TRIGGER_DIR"

if [ -f "$CAPTURE_FILE" ] && grep -qx "CALLED_WITH=lexbh" "$CAPTURE_FILE"; then
  ok "_reap_bloated_backup_staging: skipped hq (residue present) and processed lexbh instead"
else
  bad "_reap_bloated_backup_staging: expected only lexbh to be attempted, got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing')"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_bloated_backup_staging: processes at most one db per cycle (ga-74tts6) ==="
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city14.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts" "$FAKE_CITY/.dolt-backup/hq" "$FAKE_CITY/.dolt-backup/lexbh" "$FAKE_CITY/.beads/dolt/hq" "$FAKE_CITY/.beads/dolt/lexbh"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/dolt-backup-reseed.sh" <<EOF
#!/bin/bash
echo "\$1" >> "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/dolt-backup-reseed.sh"

REAL_CITY="$CITY"; REAL_DOLTDIR="$DOLTDIR"; REAL_STATE_RESEED_TRIGGER_DIR="$STATE_RESEED_TRIGGER_DIR"
CITY="$FAKE_CITY"; DOLTDIR="$FAKE_CITY/.beads/dolt"; STATE_RESEED_TRIGGER_DIR="$FAKE_CITY/state-reseed"
_reap_bloated_backup_staging 1
CITY="$REAL_CITY"; DOLTDIR="$REAL_DOLTDIR"; STATE_RESEED_TRIGGER_DIR="$REAL_STATE_RESEED_TRIGGER_DIR"

CALL_COUNT=0
[ -f "$CAPTURE_FILE" ] && CALL_COUNT=$(wc -l < "$CAPTURE_FILE" | tr -d ' ')
if [ "$CALL_COUNT" = "1" ]; then
  ok "_reap_bloated_backup_staging: exactly one db attempted per cycle even with two eligible (got: $(cat "$CAPTURE_FILE" 2>/dev/null))"
else
  bad "_reap_bloated_backup_staging: expected exactly one attempt, got $CALL_COUNT (contents: $(cat "$CAPTURE_FILE" 2>/dev/null))"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_bloated_backup_staging: per-db cooldown suppresses a repeat attempt (ga-74tts6) ==="
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city15.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts" "$FAKE_CITY/.dolt-backup/hq" "$FAKE_CITY/.beads/dolt/hq" "$FAKE_CITY/state-reseed"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/dolt-backup-reseed.sh" <<EOF
#!/bin/bash
echo "CALLED" >> "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/dolt-backup-reseed.sh"
date +%s > "$FAKE_CITY/state-reseed/hq"   # "just attempted" — well within the default cooldown

REAL_CITY="$CITY"; REAL_DOLTDIR="$DOLTDIR"; REAL_STATE_RESEED_TRIGGER_DIR="$STATE_RESEED_TRIGGER_DIR"
CITY="$FAKE_CITY"; DOLTDIR="$FAKE_CITY/.beads/dolt"; STATE_RESEED_TRIGGER_DIR="$FAKE_CITY/state-reseed"
_reap_bloated_backup_staging 1
CITY="$REAL_CITY"; DOLTDIR="$REAL_DOLTDIR"; STATE_RESEED_TRIGGER_DIR="$REAL_STATE_RESEED_TRIGGER_DIR"

[ -f "$CAPTURE_FILE" ] && bad "_reap_bloated_backup_staging: ran despite an active per-db cooldown" || ok "_reap_bloated_backup_staging: active cooldown correctly suppresses the attempt"
rm -rf "$FAKE_CITY"

echo ""
echo "=== _resurrect_dolt: escalation cooldown (ga-f4l2z, mirrors ga-q4cqr) ==="
# Tests the REAL _resurrect_dolt (still the function sourced from the
# library at this point — the main()-scenario section further below is what
# eventually stubs it out for pure wiring tests; this section MUST run
# before that happens). gc_dolt_probe_robust, GC, and escalate_emergency.py
# are all replaced with hermetic fakes for the duration of this section only
# — no real 'gc dolt start', no real notify, no real page, no real Dolt data
# touched. Uses its own disposable tmp dir throughout, independent of
# STATE_TMP (which main()'s own scenarios set up later).
RESURRECT_TEST_DIR="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-resurrect.XXXXXX)"
STATE_RESURRECT_ESCALATE_FILE="$RESURRECT_TEST_DIR/.last-resurrect-escalate"

# Fake escalator script that just records it was called (never the real
# escalate_emergency.py — no real page, no real ledger write, no real mail).
ESCALATOR_CAPTURE="$RESURRECT_TEST_DIR/calls.txt"
: > "$ESCALATOR_CAPTURE"
mkdir -p "$RESURRECT_TEST_DIR/scripts"
cat > "$RESURRECT_TEST_DIR/scripts/escalate_emergency.py" <<EOF
#!/usr/bin/env python3
with open("$ESCALATOR_CAPTURE", "a") as f:
    f.write("CALLED\n")
EOF

REAL_CITY_FOR_RESURRECT="$CITY"
REAL_GC_FOR_RESURRECT="$GC"
CITY="$RESURRECT_TEST_DIR"   # _resurrect_dolt resolves the escalator via "$CITY/scripts/..."
GC=true                      # harmless no-op standing in for `gc dolt start`
gc_dolt_probe_robust() { return 1; }   # post-attempt probe: "still down" — every call below exercises the FAILURE branch (the one with the cooldown)

_resurrect_dolt 5 NONE >/dev/null 2>&1
CALLS_AFTER_1=$(grep -c CALLED "$ESCALATOR_CAPTURE" 2>/dev/null || echo 0)
if [ "$CALLS_AFTER_1" = "1" ]; then
  ok "_resurrect_dolt: first failure escalates immediately (no wait-and-see for a confirmed outage)"
else
  bad "_resurrect_dolt: expected 1 escalator call after first failure, got $CALLS_AFTER_1"
fi

_resurrect_dolt 5 NONE >/dev/null 2>&1
CALLS_AFTER_2=$(grep -c CALLED "$ESCALATOR_CAPTURE" 2>/dev/null || echo 0)
if [ "$CALLS_AFTER_2" = "1" ]; then
  ok "_resurrect_dolt: second consecutive failure within cooldown is SUPPRESSED (ga-q4cqr precedent: no page-every-cycle)"
else
  bad "_resurrect_dolt: expected escalator call count to stay at 1 (suppressed), got $CALLS_AFTER_2"
fi

# Cooldown elapsed (simulate by backdating the state file past the window) —
# a THIRD failure must escalate again.
echo "$(( $(date +%s) - RESURRECT_ESCALATE_COOLDOWN_SECS - 1 ))" > "$STATE_RESURRECT_ESCALATE_FILE"
_resurrect_dolt 5 NONE >/dev/null 2>&1
CALLS_AFTER_3=$(grep -c CALLED "$ESCALATOR_CAPTURE" 2>/dev/null || echo 0)
if [ "$CALLS_AFTER_3" = "2" ]; then
  ok "_resurrect_dolt: failure after cooldown elapsed escalates again (persistent outage keeps paging, just not every cycle)"
else
  bad "_resurrect_dolt: expected a 2nd escalator call once cooldown elapsed, got $CALLS_AFTER_3"
fi

# INCONCLUSIVE post-restart probe (rc=2, e.g. a fresh process still settling
# under a CPU burst the robust probe couldn't rule out in time) must be
# treated as a FAILURE, not silently as success — never treat "don't know"
# as the safe-looking outcome. Verify via the LOG content specifically
# (distinct wording from the confirmed-down rc=1 case), not just the
# escalator call count already proven above for rc=1. $LOG accumulates
# across this whole suite (same as every other log-content check in this
# file), so compare COUNTS before/after this one call rather than truncating
# the shared file — truncating mid-suite would be safe here (this section
# runs before any later scenario's own log-count baseline is taken) but the
# delta approach avoids depending on that ordering fact at all.
# ga-p5q3 note on the helper itself: `grep -c PAT FILE || echo 0` is a trap
# when the real count is zero — grep -c still prints "0" to stdout on a
# no-match, but EXITS 1 (its "no lines matched" convention), so the `||`
# fires too and the substitution doubles to "0\n0", breaking arithmetic use
# downstream. Capture grep's stdout directly (always a clean integer, "0"
# included) and default only the genuinely-empty case (grep couldn't run at
# all, e.g. missing file) via parameter expansion instead.
_count() { local c; c=$(grep -c "$1" "$2" 2>/dev/null); printf '%s' "${c:-0}"; }
INCONCLUSIVE_PRE=$(_count "INCONCLUSIVE" "$LOG")
FAILED_UNREACHABLE_PRE=$(_count "FAILED — Dolt still unreachable" "$LOG")
echo "$(( $(date +%s) - RESURRECT_ESCALATE_COOLDOWN_SECS - 1 ))" > "$STATE_RESURRECT_ESCALATE_FILE"
gc_dolt_probe_robust() { return 2; }
_resurrect_dolt 5 NONE >/dev/null 2>&1
gc_dolt_probe_robust() { return 1; }   # restore for any test added after this point
CALLS_AFTER_INCONCLUSIVE=$(_count CALLED "$ESCALATOR_CAPTURE")
INCONCLUSIVE_POST=$(_count "INCONCLUSIVE" "$LOG")
FAILED_UNREACHABLE_POST=$(_count "FAILED — Dolt still unreachable" "$LOG")
if [ "$CALLS_AFTER_INCONCLUSIVE" = "3" ] \
   && [ "$INCONCLUSIVE_POST" -eq $(( INCONCLUSIVE_PRE + 1 )) ] \
   && [ "$FAILED_UNREACHABLE_POST" -eq "$FAILED_UNREACHABLE_PRE" ]; then
  ok "_resurrect_dolt: inconclusive post-restart probe (rc=2) is treated as failure (escalates) and logged distinctly from a confirmed-down (rc=1) failure"
else
  bad "_resurrect_dolt: inconclusive-probe handling wrong (escalator_calls=$CALLS_AFTER_INCONCLUSIVE, INCONCLUSIVE lines pre/post=$INCONCLUSIVE_PRE/$INCONCLUSIVE_POST, FAILED-unreachable lines pre/post=$FAILED_UNREACHABLE_PRE/$FAILED_UNREACHABLE_POST)"
fi

# Success path: probe flips to healthy (rc=0) after the start attempt — must
# notify (not escalate) and must NOT touch the escalator at all.
NOTIFY_SUCCESS_CALLS=0
NOTIFY=record_notify_resurrect_success
record_notify_resurrect_success() { NOTIFY_SUCCESS_CALLS=$((NOTIFY_SUCCESS_CALLS+1)); }
gc_dolt_probe_robust() { return 0; }
CALLS_BEFORE_SUCCESS=$(grep -c CALLED "$ESCALATOR_CAPTURE" 2>/dev/null || echo 0)
_resurrect_dolt 12 WARN >/dev/null 2>&1
CALLS_AFTER_SUCCESS=$(grep -c CALLED "$ESCALATOR_CAPTURE" 2>/dev/null || echo 0)
if [ "$NOTIFY_SUCCESS_CALLS" = "1" ] && [ "$CALLS_AFTER_SUCCESS" = "$CALLS_BEFORE_SUCCESS" ]; then
  ok "_resurrect_dolt: successful restart (probe healthy after start) notifies once and never escalates"
else
  bad "_resurrect_dolt: success path wrong (notify_calls=$NOTIFY_SUCCESS_CALLS escalator_calls_before=$CALLS_BEFORE_SUCCESS after=$CALLS_AFTER_SUCCESS)"
fi

rm -rf "$RESURRECT_TEST_DIR"
CITY="$REAL_CITY_FOR_RESURRECT"
GC="$REAL_GC_FOR_RESURRECT"
unset -f gc_dolt_probe_robust record_notify_resurrect_success 2>/dev/null || true

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
# ga-q4cqr: MUST be redirected exactly like the two state files above — it was
# evaluated at SOURCE time against the real $CITY/.gc/logs (before this
# override runs), and _read_critical_sustain/_write_critical_sustain reference
# the variable by name at call time, so without this line every scenario below
# would read/write the REAL production sustain-count file instead of this
# disposable one (caught live: a first draft of this suite leaked a stray
# `.dolt-disk-floor-guard.critical-sustain-count` file into the real
# $CITY/.gc/logs before this redirect was added).
STATE_CRITICAL_SUSTAIN_FILE="$STATE_TMP/.critical-sustain-count"

# ga-4f4opx: same MUST-redirect trap as STATE_CRITICAL_SUSTAIN_FILE's own
# comment immediately above documents, and this suite repeated it live once
# already (first draft of THIS bead's tests leaked
# `.dolt-disk-floor-guard.critical-episode-mailed` into the real
# $CITY/.gc/logs before this redirect was added — caught via mtime on the
# real file, matching the exact failure mode the comment above already
# warns about). All three new state vars are evaluated at SOURCE time
# against the real $STATE_DIR default, so they MUST be reassigned here too.
STATE_LAST_MAIL_EPOCH_FILE="$STATE_TMP/.last-mail-epoch"
STATE_LAST_MAIL_AVAIL_FILE="$STATE_TMP/.last-mail-avail-gb"
STATE_CRITICAL_EPISODE_MAILED_FILE="$STATE_TMP/.critical-episode-mailed"

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
# _vm_swap_gb is real, hermetic (du -sk, read-only, already proven correct in
# isolation above) but STUBBED here anyway so these main()-scenario
# assertions don't depend on this host's actual VM-swap size at test time —
# a fixed, known value lets the log-line assertion below (Scenario A) check
# the EXACT logged number instead of merely "some number" (ga-sfj3i.2).
_vm_swap_gb() { echo "7"; }
# _top_mem_processes is real, hermetic (top -l 1 + ps + launchctl,
# read-only, already proven correct in isolation above) but STUBBED here
# anyway so main()-scenario assertions on log/mail content don't depend on
# this host's actual process table at test time — same rationale as the
# _vm_swap_gb stub immediately above (ga-sfj3i.3, ga-xz5re).
_top_mem_processes() { printf '%s\n' "51664 1 1870M 302M com.gastown.dolt-server dolt" "11357 1 253M 4M - claude"; }

# _top_disk_consumers is new (ga-ofi307), same reasoning as _top_mem_processes
# immediately above: real and hermetic in isolation (proven with its own
# fixture below), but STUBBED here so main()-scenario assertions on log/mail
# content don't depend on this host's actual scratch/cache directory sizes at
# test time — and so this whole suite doesn't pay this function's real,
# measured ~20-40s cost (multiple `find | xargs du` passes over this host's
# actual DARWIN_USER_TEMP_DIR and ~/Library/Caches) on EVERY main() scenario
# that reaches the notify branch, same rationale as the _top_mem_processes
# stub.
_top_disk_consumers() { printf '%s\n' "3583 /private/tmp/claude-501/bash-edit-diff" "812 /var/folders/gj/T/pytest-of-athos"; }

# _growth_episode_photo / _growth_baseline_refresh are new (ga-ond0fa), same
# reasoning as _top_disk_consumers above: real and hermetic in isolation (proven
# with fixture directories in the disk-growth section earlier in this file) but
# STUBBED here so no main() scenario pays a real scan of this host's directories.
# The stub for the photo snapshots the reclaim-lever call counters AT CALL TIME
# ("0/0/0/0/0" proves it ran BEFORE every lever — the ordering the feature exists
# for: the levers delete the scratch/caches a growth photo must still see). The
# counters are read by name at call time, so defining this before they exist is
# fine. GROWTH_* capture vars are reset by reset_capture.
GROWTH_PHOTO_CALLS=0; GROWTH_PHOTO_LAST_CLASS=""; GROWTH_PHOTO_LAST_AVAIL=""; GROWTH_PHOTO_REAP_AT_CALL=""
_growth_episode_photo() {
  GROWTH_PHOTO_CALLS=$((GROWTH_PHOTO_CALLS+1)); GROWTH_PHOTO_LAST_CLASS="$1"; GROWTH_PHOTO_LAST_AVAIL="$2"
  GROWTH_PHOTO_REAP_AT_CALL="$REAP_CALLS/$REAP_TRANSCRIPT_CALLS/$REAP_HF_CALLS/$REAP_GOCACHE_CALLS/$REAP_BACKUP_STAGING_CALLS"
}
GROWTH_BASELINE_CALLS=0
_growth_baseline_refresh() { GROWTH_BASELINE_CALLS=$((GROWTH_BASELINE_CALLS+1)); }

# _safe_reclaim's own mechanics (gc dolt-cleanup --force, health probe) are
# EXECUTION code out of scope for this file (see section banner above) —
# stubbed as a no-op here too, same as every other main()-only side effect.
_safe_reclaim() { :; }

# gc_dolt_probe_robust / _resurrect_dolt (ga-f4l2z): EXECUTION code out of
# scope for this file — shells out to a real `gc dolt start` restart and a
# real escalate_emergency.py page. Stubbed so main()'s WIRING to
# _should_resurrect is what gets proven, never a real Dolt restart, real
# notify, or real page. RESURRECT_PROBE_RC drives gc_dolt_probe_robust's
# return code per-scenario (0/1/2, matching its real contract); RESURRECT_
# CALLS/LAST_AVAIL/LAST_CLASS capture whether+how main() invoked
# _resurrect_dolt, without ever running the real one.
RESURRECT_PROBE_RC=0
gc_dolt_probe_robust() { return "$RESURRECT_PROBE_RC"; }
RESURRECT_CALLS=0; RESURRECT_LAST_AVAIL=""; RESURRECT_LAST_CLASS=""
_resurrect_dolt() { RESURRECT_CALLS=$((RESURRECT_CALLS+1)); RESURRECT_LAST_AVAIL="$1"; RESURRECT_LAST_CLASS="$2"; }

# _reap_dead_scratch is new (ga-02pnu): stubbed as a no-op for the SAME reason
# _safe_reclaim is — it's EXECUTION code (shells out to scratchpad-reaper.sh,
# which has its own independent selftest). REAP_CALLS proves main() actually
# invokes it as part of the reclaim step (integration wiring), without ever
# running the real reaper (no `gc session list`, no `rm -rf`, hermetic).
# REAP_LAST_ARG (ga-rjhfz) captures the was_critical arg main() passes, so a
# scenario below can prove the CRITICAL-latch value actually reaches this
# call, not just that the call happened.
REAP_CALLS=0
REAP_LAST_ARG=""
_reap_dead_scratch() { REAP_CALLS=$((REAP_CALLS+1)); REAP_LAST_ARG="${1:-}"; }

# _reap_dead_transcripts is new (ga-t1ub9), same reasoning: EXECUTION code
# (shells out to transcript-reaper.sh, which has its own independent unit +
# integration selftest) stubbed as a no-op here so main()'s WIRING is what
# gets proven, not the real reaper's file-deletion logic.
REAP_TRANSCRIPT_CALLS=0
_reap_dead_transcripts() { REAP_TRANSCRIPT_CALLS=$((REAP_TRANSCRIPT_CALLS+1)); }

# _reap_growing_logs is new (ga-dnc2m), same reasoning as the other two reap
# stubs: EXECUTION code (shells out to log-reaper.sh, which has its own
# independent selftest) stubbed as a no-op here so main()'s WIRING is what
# gets proven. REAP_LOGS_CALLS is checked in Scenario F below specifically
# BECAUSE it must behave differently from the other two — see that scenario.
REAP_LOGS_CALLS=0
_reap_growing_logs() { REAP_LOGS_CALLS=$((REAP_LOGS_CALLS+1)); }

# _reap_hf_cache is new (wa-9eh0v), same reasoning as the other reap stubs:
# EXECUTION code (shells out to hf_cache_reap.py via the recall-venv, which
# has its own dedicated wiring tests earlier in this file) stubbed as a
# no-op here so main()'s WIRING is what gets proven. REAP_HF_LAST_ARG mirrors
# REAP_LAST_ARG above — this lever also receives was_critical as $1, and
# Scenario E/E2 below prove it must be CALLED at all only when CRITICAL
# (unlike the other three, which run at WARN too).
REAP_HF_CALLS=0
REAP_HF_LAST_ARG=""
_reap_hf_cache() { REAP_HF_CALLS=$((REAP_HF_CALLS+1)); REAP_HF_LAST_ARG="${1:-}"; }

# _reap_gocache is new (ga-yi68q), same reasoning as the other reap stubs:
# EXECUTION code (shells out to `go clean -cache` directly, no delegate
# script — see that function's own header for why) stubbed as a no-op here
# so main()'s WIRING is what gets proven, not the real cache wipe. Grouped
# with scratch/transcript/logs (called on EVERY cycle that reaches the
# reclaim step, was_critical passed as $1, decision logic lives INSIDE the
# real function via _should_reap_gocache) — NOT with hf_cache, which main()
# itself never gates differently; hf_cache's CRITICAL-only behavior also
# lives inside its own function, but this comment exists on both because a
# future reader must not assume "reaches main() unconditionally" implies
# "always actually reaps" for either lever.
REAP_GOCACHE_CALLS=0
REAP_GOCACHE_LAST_ARG=""
_reap_gocache() { REAP_GOCACHE_CALLS=$((REAP_GOCACHE_CALLS+1)); REAP_GOCACHE_LAST_ARG="${1:-}"; }

# _reap_go_build_orphans is new (ga-ilmjgo), same reasoning as the other reap
# stubs: EXECUTION code (real directory walk + real lsof + real rm, already
# proven in isolation with a hermetic fixture earlier in this file) stubbed
# as a no-op here so main()'s WIRING is what gets proven — never a real scan
# of this host's actual DARWIN_USER_TEMP_DIR. Takes no was_critical arg
# (unlike scratch/hf-cache/gocache) — this lever's WARN-vs-CRITICAL decision
# is per-directory (the lsof liveness check), not a global two-tier gate, so
# there is nothing for main() itself to pass.
REAP_GO_BUILD_CALLS=0
_reap_go_build_orphans() { REAP_GO_BUILD_CALLS=$((REAP_GO_BUILD_CALLS+1)); }

# _reap_code_sign_clone_orphans is new (ga-nkqook), same reasoning as
# _reap_go_build_orphans's stub immediately above: EXECUTION code (real
# directory walk + real lsof + real rm, already proven in isolation with a
# hermetic fixture earlier in this file) stubbed as a no-op here so main()'s
# WIRING is what gets proven — never a real scan of this host's actual
# code_sign_clone dir. Takes no was_critical arg, same reasoning as
# _reap_go_build_orphans (per-directory lsof liveness, not a global two-tier
# gate).
REAP_CODE_SIGN_CLONE_CALLS=0
_reap_code_sign_clone_orphans() { REAP_CODE_SIGN_CLONE_CALLS=$((REAP_CODE_SIGN_CLONE_CALLS+1)); }

# _reap_bash_edit_diff_orphans is new (ga-ofi307), same reasoning as
# _reap_go_build_orphans/_reap_code_sign_clone_orphans's stubs immediately
# above: EXECUTION code (real directory walk + real rm, already proven in
# isolation with a hermetic fixture earlier in this file) stubbed as a no-op
# here so main()'s WIRING is what gets proven — never a real scan of this
# host's actual /private/tmp/claude-<uid>/bash-edit-diff. Takes no
# was_critical arg, same reasoning as its two orphan-reap siblings (age-only
# grace, no two-tier gate for main() to pass).
REAP_BASH_EDIT_DIFF_CALLS=0
_reap_bash_edit_diff_orphans() { REAP_BASH_EDIT_DIFF_CALLS=$((REAP_BASH_EDIT_DIFF_CALLS+1)); }

# _reap_orphan_test_dolt_processes is new (ga-fqj42), same reasoning as its
# three orphan-reap siblings immediately above: EXECUTION code (real pgrep
# enumeration + real ps introspection + real kill -TERM, already proven in
# isolation with a hermetic faked-pgrep/ps fixture earlier in this file)
# stubbed as a no-op here so main()'s WIRING is what gets proven — never a
# real process scan of this host. Takes no was_critical arg, same reasoning
# as its siblings: the discriminator (ppid==1 AND test-tmp --config) is a
# per-candidate classification, not a global two-tier gate.
REAP_ORPHAN_TEST_DOLT_CALLS=0
_reap_orphan_test_dolt_processes() { REAP_ORPHAN_TEST_DOLT_CALLS=$((REAP_ORPHAN_TEST_DOLT_CALLS+1)); }

# _reap_backup_residue is new (ga-8f1uh0), same reasoning as
# _reap_go_build_orphans/_reap_code_sign_clone_orphans's stubs immediately
# above: EXECUTION code (shells out to dolt-backup-residue-reclaim.sh, which
# has its own independent unit + stubbed-integration selftest covering the
# real S3-verification/deletion logic) stubbed as a no-op here so main()'s
# WIRING is what gets proven — never a real AWS call or real deletion. Takes
# no was_critical arg, same reasoning as the other two orphan-reap levers:
# releasing S3-verified residue is safe at either tier, so there is nothing
# for main() itself to gate.
REAP_BACKUP_RESIDUE_CALLS=0
_reap_backup_residue() { REAP_BACKUP_RESIDUE_CALLS=$((REAP_BACKUP_RESIDUE_CALLS+1)); }

# _reap_bloated_backup_staging is new (ga-74tts6), same reasoning as
# _reap_backup_residue's stub immediately above: EXECUTION code (shells out to
# dolt-backup-reseed.sh, which has its own independent hermetic selftest
# covering the real low-disk/ultra-low-disk logic, plus this file's own
# isolated tests above covering the wiring — db enumeration, residue-skip,
# one-per-cycle, cooldown) stubbed as a no-op here so main()'s WIRING is what
# gets proven — never a real reseed. Takes was_critical as $1, same reasoning
# as _reap_hf_cache/_reap_gocache: the CRITICAL-only gate lives INSIDE the
# real function, not in main()'s wiring, so this must be called (and
# captured) on every cycle that reaches the reclaim step, regardless of tier.
REAP_BACKUP_STAGING_CALLS=0
REAP_BACKUP_STAGING_LAST_ARG=""
_reap_bloated_backup_staging() { REAP_BACKUP_STAGING_CALLS=$((REAP_BACKUP_STAGING_CALLS+1)); REAP_BACKUP_STAGING_LAST_ARG="${1:-}"; }

NOTIFY_CALLS=0; NOTIFY_LAST_PRIO=""; NOTIFY_LAST_MSG=""; NOTIFY_LAST_FORCE_PUSH=""
record_notify() {
  NOTIFY_CALLS=$((NOTIFY_CALLS+1))
  # ga-ff6t9: capture whether THIS call was force-pushed (env var set only
  # for the duration of this function call by the SUT's own
  # `NOTIFY_FORCE_PUSH=1 "$NOTIFY" ...` prefix — verified empirically that a
  # bash env-var prefix on a function call IS visible inside it and reverts
  # after). Read fresh every call so a later non-forced call doesn't inherit
  # a stale "1" from an earlier one.
  NOTIFY_LAST_FORCE_PUSH="${NOTIFY_FORCE_PUSH:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) NOTIFY_LAST_PRIO="$2"; shift 2 ;;
      # ga-sfj3i.3: capture the message text too (last positional arg wins,
      # same loop shape as before — -t's title value passes through here
      # too, but the actual message is genuinely the LAST token processed).
      *) NOTIFY_LAST_MSG="$1"; shift ;;
    esac
  done
}
# shellcheck disable=SC2034  # read by main() in the sourced script
NOTIFY=record_notify

GC_MAIL_CALLS=0; GC_MAIL_LAST_BODY=""
record_gc() {
  if [ "$1" = "mail" ] && [ "$2" = "send" ]; then
    GC_MAIL_CALLS=$((GC_MAIL_CALLS+1))
    GC_MAIL_LAST_BODY=""
    shift 2
    # ga-sfj3i.3: capture the -m body too, so scenarios can assert on the
    # actual diagnosis/RSS content mailed to the Mayor, not just the count.
    while [ $# -gt 0 ]; do
      case "$1" in
        -m) GC_MAIL_LAST_BODY="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
  fi
}
# shellcheck disable=SC2034  # read by main() in the sourced script
GC=record_gc

reset_capture() { NOTIFY_CALLS=0; NOTIFY_LAST_PRIO=""; NOTIFY_LAST_MSG=""; NOTIFY_LAST_FORCE_PUSH=""; GC_MAIL_CALLS=0; GC_MAIL_LAST_BODY=""; REAP_CALLS=0; REAP_LAST_ARG=""; REAP_TRANSCRIPT_CALLS=0; REAP_LOGS_CALLS=0; REAP_HF_CALLS=0; REAP_HF_LAST_ARG=""; REAP_GOCACHE_CALLS=0; REAP_GOCACHE_LAST_ARG=""; REAP_GO_BUILD_CALLS=0; REAP_CODE_SIGN_CLONE_CALLS=0; REAP_BASH_EDIT_DIFF_CALLS=0; REAP_ORPHAN_TEST_DOLT_CALLS=0; REAP_BACKUP_RESIDUE_CALLS=0; REAP_BACKUP_STAGING_CALLS=0; REAP_BACKUP_STAGING_LAST_ARG=""; RESURRECT_CALLS=0; RESURRECT_LAST_AVAIL=""; RESURRECT_LAST_CLASS=""; RESURRECT_PROBE_RC=0; GROWTH_PHOTO_CALLS=0; GROWTH_PHOTO_LAST_CLASS=""; GROWTH_PHOTO_LAST_AVAIL=""; GROWTH_PHOTO_REAP_AT_CALL=""; GROWTH_BASELINE_CALLS=0; rm -f "$(_growth_episode_file)";
  # ga-4f4opx: clear the mail-debounce/recovery state too, so every scenario
  # starts with a clean slate by default (no leftover "already mailed this
  # avail" or "episode already mailed" from whichever scenario ran before
  # it) unless it explicitly opts in via seed_last_mail/
  # seed_critical_episode_mailed below — mirrors seed_state/
  # seed_critical_sustain's own explicit-seed convention, just defaulted to
  # empty here since reset_capture already runs at the top of every scenario.
  rm -f "$STATE_LAST_MAIL_EPOCH_FILE" "$STATE_LAST_MAIL_AVAIL_FILE" "$STATE_CRITICAL_EPISODE_MAILED_FILE";
}
seed_state() {
  if [ -n "$1" ]; then echo "$1" > "$STATE_EPOCH_FILE"; else rm -f "$STATE_EPOCH_FILE"; fi
  if [ -n "$2" ]; then echo "$2" > "$STATE_AVAIL_FILE"; else rm -f "$STATE_AVAIL_FILE"; fi
}
# ga-q4cqr: seed/read the CRITICAL-mail sustain counter directly, so scenarios
# can set up "already N cycles into a streak" without needing N real main()
# calls, and can verify main() left the expected count behind afterward.
seed_critical_sustain() {
  if [ -n "$1" ]; then echo "$1" > "$STATE_CRITICAL_SUSTAIN_FILE"; else rm -f "$STATE_CRITICAL_SUSTAIN_FILE"; fi
}
read_critical_sustain_state() { [ -f "$STATE_CRITICAL_SUSTAIN_FILE" ] && cat "$STATE_CRITICAL_SUSTAIN_FILE" || echo ""; }

# ga-4f4opx: seed/read the new mail-debounce + recovery-episode state, same
# explicit-seed shape as seed_state/seed_critical_sustain above.
seed_last_mail() {
  if [ -n "$1" ]; then echo "$1" > "$STATE_LAST_MAIL_EPOCH_FILE"; else rm -f "$STATE_LAST_MAIL_EPOCH_FILE"; fi
  if [ -n "$2" ]; then echo "$2" > "$STATE_LAST_MAIL_AVAIL_FILE"; else rm -f "$STATE_LAST_MAIL_AVAIL_FILE"; fi
}
seed_critical_episode_mailed() {
  if [ -n "$1" ]; then echo "$1" > "$STATE_CRITICAL_EPISODE_MAILED_FILE"; else rm -f "$STATE_CRITICAL_EPISODE_MAILED_FILE"; fi
}
read_last_mail_epoch_state() { [ -f "$STATE_LAST_MAIL_EPOCH_FILE" ] && cat "$STATE_LAST_MAIL_EPOCH_FILE" || echo ""; }
read_last_mail_avail_state() { [ -f "$STATE_LAST_MAIL_AVAIL_FILE" ] && cat "$STATE_LAST_MAIL_AVAIL_FILE" || echo ""; }
read_critical_episode_mailed_state() { [ -f "$STATE_CRITICAL_EPISODE_MAILED_FILE" ] && cat "$STATE_CRITICAL_EPISODE_MAILED_FILE" || echo ""; }

# Scenario A — repro path (a) from the GATE-FEEDBACK: CRITICAL (2GB) fully
# recovers to NONE (20GB) after reclaim. Pre-fix, main() hit the early return
# "back above floor after reclaim — no notify needed" and NEITHER notify nor
# mail-Mayor ever fired for a reading that was CRITICAL moments earlier.
# ga-q4cqr: mail is now sustain-gated (default threshold 2) — a single
# CRITICAL cycle notifies immediately (prio 5, unconditional per imp07) but
# must NOT yet mail; it should leave a pending count of 1 behind for the next
# cycle to potentially confirm. See Scenario A2 for the 2nd-cycle confirm.
reset_capture; seed_state "" ""; seed_critical_sustain ""
queue_avail 2 20
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "5" ] && [ "$GC_MAIL_CALLS" = "0" ] && [ "$(read_critical_sustain_state)" = "1" ] && [ "$NOTIFY_LAST_FORCE_PUSH" = "1" ]; then
  ok "main(): CRITICAL avail fully recovered by reclaim still notifies (prio 5, force-push); mail debounced (pending 1/2)"
else
  bad "main(): CRITICAL->NONE recovery — notify/debounce/force-push wrong (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO mail_calls=$GC_MAIL_CALLS pending=$(read_critical_sustain_state) force_push='$NOTIFY_LAST_FORCE_PUSH')"
fi
if grep -q "vm_swap_gb=7" "$LOG" 2>/dev/null; then
  ok "main(): logs vm_swap_gb as its own metric line every cycle, not just on breach (ga-sfj3i.2)"
else
  bad "main(): expected a 'vm_swap_gb=7' log line this cycle, log contains: $(tr '\n' ';' < "$LOG" 2>/dev/null | tail -c 300)"
fi

# Scenario A2 — ga-q4cqr sustain confirm: a SECOND consecutive CRITICAL cycle
# (pending already 1 from a prior cycle) must confirm the streak and mail the
# Mayor this time, while notify keeps firing unconditionally every cycle
# regardless (same as before this bead — only mail is new/gated).
reset_capture; seed_state "" ""; seed_critical_sustain 1
queue_avail 2 20
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "5" ] && [ "$GC_MAIL_CALLS" = "1" ] && [ "$(read_critical_sustain_state)" = "2" ]; then
  ok "main(): 2nd consecutive CRITICAL cycle confirms sustain (2/2) — mails Mayor"
else
  bad "main(): 2nd consecutive CRITICAL cycle should confirm + mail (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO mail_calls=$GC_MAIL_CALLS pending=$(read_critical_sustain_state))"
fi

# Scenario A3 — ga-q4cqr streak reset: a non-critical cycle between two
# CRITICAL cycles must reset the sustain counter, so the second CRITICAL
# cycle (pending resets to 1, not 3) does NOT prematurely mail. Reuses
# Scenario D's readings (6 -> 20, fully resolved, non-critical) to perform
# the reset, then a fresh CRITICAL cycle.
reset_capture; seed_state "" ""; seed_critical_sustain 1
queue_avail 6 20
main
if [ "$(read_critical_sustain_state)" != "0" ]; then
  bad "main(): non-critical cycle should reset sustain count to 0, got '$(read_critical_sustain_state)'"
else
  reset_capture
  queue_avail 2 20
  main
  if [ "$GC_MAIL_CALLS" = "0" ] && [ "$(read_critical_sustain_state)" = "1" ]; then
    ok "main(): sustain streak correctly reset by an intervening non-critical cycle (next CRITICAL starts back at 1/2, does not prematurely mail)"
  else
    bad "main(): streak reset didn't take — next CRITICAL cycle should start at 1/2 (mail_calls=$GC_MAIL_CALLS pending=$(read_critical_sustain_state))"
  fi
fi

# Scenario A4 — ga-4f4opx repro: a THIRD consecutive CRITICAL cycle (no reset
# in between, sustain already confirmed+mailed once at avail=2GB, recently)
# must NOT mail the Mayor again — same avail, well within the 2h cooldown, no
# new minimum. This is the actual measured bug (32 of 65 Mayor mails in one
# night, one per 5min cycle): pre-fix, _sustain_confirmed alone gated the
# mail and stayed true forever once the streak crossed 2, so THIS cycle would
# have mailed again. NOTIFY must still fire unconditionally (imp07,
# unaffected by this bead).
reset_capture; seed_state "" ""; seed_critical_sustain 2
seed_last_mail "$(( $(date +%s) - 60 ))" 2
queue_avail 2 2
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "5" ] && [ "$GC_MAIL_CALLS" = "0" ] && [ "$(read_critical_sustain_state)" = "3" ]; then
  ok "main(): 3rd consecutive CRITICAL cycle (unchanged avail, within cooldown) suppresses the repeat Mayor mail — ga-4f4opx fixed; notify still unconditional"
else
  bad "main(): 3rd consecutive CRITICAL cycle should suppress repeat mail (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO mail_calls=$GC_MAIL_CALLS pending=$(read_critical_sustain_state))"
fi

# Scenario A5 — ga-4f4opx: a new relevant minimum (avail dropped by
# >= CRITICAL_MAIL_MIN_DROP_GB since the last mail) DOES re-mail, even well
# within the 2h cooldown — acceptance criteria (a). Last mail was at 2GB;
# this cycle reads 1GB both before and after reclaim (no recovery).
reset_capture; seed_state "" ""; seed_critical_sustain 2
seed_last_mail "$(( $(date +%s) - 60 ))" 2
queue_avail 1 1
main
if [ "$GC_MAIL_CALLS" = "1" ] && [ "$(read_last_mail_avail_state)" = "1" ]; then
  ok "main(): a new relevant minimum (2GB -> 1GB) re-mails the Mayor even within cooldown (ga-4f4opx acceptance (a)), and records the new last-mailed avail"
else
  bad "main(): a new minimum should have re-mailed (mail_calls=$GC_MAIL_CALLS last_mailed_avail=$(read_last_mail_avail_state))"
fi

# Scenario A6 — ga-4f4opx: the mail cooldown elapsing (>= 2h since the last
# mail) DOES re-mail even at an unchanged avail — acceptance criteria (b).
reset_capture; seed_state "" ""; seed_critical_sustain 2
seed_last_mail "$(( $(date +%s) - 7201 ))" 2
queue_avail 2 2
main
if [ "$GC_MAIL_CALLS" = "1" ]; then
  ok "main(): mail cooldown elapsed (>2h) re-mails the Mayor even at unchanged avail (ga-4f4opx acceptance (b))"
else
  bad "main(): elapsed mail cooldown should have re-mailed, GC_MAIL_CALLS=$GC_MAIL_CALLS"
fi

# Scenario A7 — ga-4f4opx recovery mail: after this guard already mailed the
# Mayor at least once this CRITICAL episode, the FIRST fully-recovered cycle
# (avail comfortably above the WARN floor, pre-reclaim NONE — the early-return
# path) must send exactly one recovery mail and clear the episode-mailed +
# mail-debounce state, so a FUTURE new CRITICAL episode's first mail is
# unconditional again. "Manter... o [aviso] de recuperação" — the acceptance
# criteria's explicit third requirement.
reset_capture; seed_state "" ""; seed_critical_sustain 2
seed_last_mail "$(( $(date +%s) - 60 ))" 2
seed_critical_episode_mailed 1
queue_avail 20
main
if [ "$GC_MAIL_CALLS" = "1" ] && [ "$(read_critical_episode_mailed_state)" = "0" ] && [ "$(read_last_mail_epoch_state)" = "" ] && [ "$(read_last_mail_avail_state)" = "" ]; then
  ok "main(): first fully-recovered cycle after a mailed CRITICAL episode sends ONE recovery mail and clears mail-debounce state"
else
  bad "main(): recovery mail wrong (mail_calls=$GC_MAIL_CALLS episode_mailed=$(read_critical_episode_mailed_state) last_epoch='$(read_last_mail_epoch_state)' last_avail='$(read_last_mail_avail_state)')"
fi

# Scenario A7b — the SAME recovery must never repeat on a SECOND consecutive
# recovered cycle — episode-mailed was already cleared by A7, so this is a
# genuine non-regression (not just "cooldown" — the flag itself is gone).
reset_capture
queue_avail 20
main
if [ "$GC_MAIL_CALLS" = "0" ]; then
  ok "main(): a second consecutive recovered cycle does NOT repeat the recovery mail (episode-mailed flag already cleared)"
else
  bad "main(): recovery mail repeated on a cycle that already recovered, GC_MAIL_CALLS=$GC_MAIL_CALLS"
fi

# Scenario A8 — non-regression: a cycle that recovers WITHOUT this guard ever
# having mailed the Mayor this episode (ordinary WARN dip that self-resolved,
# or a CRITICAL streak that never reached CRITICAL_MAIL_SUSTAIN) must NOT
# send a recovery mail — nothing to close out, same "don't alert on what
# nobody was told about" principle the sustain gate already applies to the
# first mail.
reset_capture; seed_state "" ""; seed_critical_sustain ""
queue_avail 20
main
if [ "$GC_MAIL_CALLS" = "0" ]; then
  ok "main(): recovery from a dip that never mailed the Mayor stays silent on the mail channel (no phantom recovery mail)"
else
  bad "main(): should never mail a recovery for an episode that was never mailed, GC_MAIL_CALLS=$GC_MAIL_CALLS"
fi

# Scenario B — repro path (b), reviewer's exact numbers (WARN=8 CRIT=3
# cooldown=3600): CRITICAL (2GB) reclaims back to EXACTLY the WARN floor
# (8GB), within cooldown and not "worsening" vs. a last-notified avail of
# 8GB. Pre-fix, class was reclassified WARN post-reclaim and ordinary WARN
# cooldown/worsening suppression swallowed the CRITICAL-only mail-Mayor alert.
# ga-q4cqr: seeds sustain=1 explicitly (this cycle is the CONFIRMING 2nd) so
# this scenario stays self-contained/order-independent and keeps proving its
# original point — cooldown/worsening suppression must never swallow an
# already-sustain-confirmed CRITICAL mail — rather than accidentally passing
# on leftover state from whichever scenario happened to run before it.
reset_capture
past_epoch=$(( $(date +%s) - 600 ))
seed_state "$past_epoch" 8
seed_critical_sustain 1
queue_avail 2 8
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "5" ] && [ "$GC_MAIL_CALLS" = "1" ] && [ "$NOTIFY_LAST_FORCE_PUSH" = "1" ]; then
  ok "main(): CRITICAL avail partially recovered into WARN tier still bypasses cooldown + mails Mayor + force-pushes (sustain already confirmed) — proves the force-push gate keys off was_critical, not the recomputed post-reclaim class"
else
  bad "main(): CRITICAL->WARN partial recovery lost the always-notify/mail-Mayor/force-push guarantee (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO mail_calls=$GC_MAIL_CALLS force_push='$NOTIFY_LAST_FORCE_PUSH')"
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
echo "=== main(): VM-bound vs file-bound diagnosis (ga-sfj3i.3) ==="
# WHY: the real incident this bead exists for — the 4 reclaim levers ran,
# reclaimed ~0 bytes, and the guard said "reclaim OK — avail X -> X" while
# 15GB sat in /System/Volumes/VM. These scenarios prove the alert now
# distinguishes "cleanup will help" from "cleanup cannot help" instead of
# emitting the same text either way. Default VM_SIGNIFICANT_GB=2 throughout
# (not overridden).

# Scenario G — VM-bound CRITICAL: reclaim achieves nothing (2GB -> 2GB) AND
# vm_swap (stubbed 7GB, well above the 2GB threshold) is significant. Must
# say explicitly that cleanup will not help and name the GB figure — the
# bead's own item 2 wording.
reset_capture; seed_state "" ""; seed_critical_sustain 1
queue_avail 2 2
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "5" ]; then
  ok "main(): VM-bound CRITICAL still notifies unconditionally (prio 5)"
else
  bad "main(): VM-bound CRITICAL notify wrong (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO)"
fi
case "$NOTIFY_LAST_MSG" in
  *"will NOT resolve"*"7GB"*) ok "main(): VM-bound notify message states cleanup will not resolve it, with the GB figure" ;;
  *) bad "main(): VM-bound notify message missing the explicit non-resolution statement — got: $NOTIFY_LAST_MSG" ;;
esac
if [ "$GC_MAIL_CALLS" = "1" ]; then
  case "$GC_MAIL_LAST_BODY" in
    *"will NOT resolve"*"reducing RAM pressure"*"51664 1 1870M 302M com.gastown.dolt-server dolt"*)
      ok "main(): VM-bound mail body states the RAM-pressure-only remedy AND includes the top memory-footprint listing" ;;
    *)
      bad "main(): VM-bound mail body missing diagnosis and/or memory-footprint listing — got: $(printf '%s' "$GC_MAIL_LAST_BODY" | tr '\n' ';' | cut -c1-400)" ;;
  esac
else
  bad "main(): expected VM-bound CRITICAL (sustain already 1) to confirm and mail this cycle, GC_MAIL_CALLS=$GC_MAIL_CALLS"
fi
if grep -q "diagnosis:.*VM-bound\|diagnosis:.*NOT resolve" "$LOG" 2>/dev/null; then
  ok "main(): VM-bound diagnosis is logged for the permanent record"
else
  bad "main(): no VM-bound diagnosis line found in LOG"
fi

# Scenario H — file-bound CRITICAL: reclaim actually recovers a lot (2GB ->
# 20GB) while vm_swap is stubbed low (1GB, below the 2GB threshold). Must
# credit file cleanup, NOT claim virtual memory is the blocker — opposite
# remedies must not produce the same message (bead item 3).
reset_capture; seed_state "" ""; seed_critical_sustain 1
_vm_swap_gb() { echo "1"; }
queue_avail 2 20
main
_vm_swap_gb() { echo "7"; }   # restore default stub for later scenarios
case "$NOTIFY_LAST_MSG" in
  *"will NOT resolve"*) bad "main(): file-bound case wrongly claimed VM is the blocker — got: $NOTIFY_LAST_MSG" ;;
  *"recovered 18GB"*)   ok "main(): file-bound notify message credits file cleanup with the actual GB recovered" ;;
  *) bad "main(): file-bound notify message missing the recovered-GB framing — got: $NOTIFY_LAST_MSG" ;;
esac
case "$GC_MAIL_LAST_BODY" in
  *"will NOT resolve"*) bad "main(): file-bound mail body wrongly used the VM-bound framing" ;;
  *"cleanup worked"*)   ok "main(): file-bound mail body uses the file-cleanup-worked framing, not the VM one" ;;
  *) bad "main(): file-bound mail body missing the cleanup-worked framing — got: $(printf '%s' "$GC_MAIL_LAST_BODY" | tr '\n' ';' | cut -c1-400)" ;;
esac

# Scenario I — unresolved CRITICAL: reclaim achieves nothing (2GB -> 2GB) AND
# vm_swap (1GB) is below the significance threshold too. Neither known cause
# applies — must say so honestly rather than guessing one of the two.
reset_capture; seed_state "" ""; seed_critical_sustain 1
_vm_swap_gb() { echo "1"; }
queue_avail 2 2
main
_vm_swap_gb() { echo "7"; }   # restore default stub for later scenarios
case "$NOTIFY_LAST_MSG" in
  *"will NOT resolve"*|*"recovered"*) bad "main(): unresolved case wrongly claimed a specific known cause — got: $NOTIFY_LAST_MSG" ;;
  *"cause not identified"*)           ok "main(): unresolved case honestly states neither known cause applies" ;;
  *) bad "main(): unresolved notify message missing the honest-unknown framing — got: $NOTIFY_LAST_MSG" ;;
esac

# Scenario I2 (ga-ofi307, acceptance test 2/3): the exact "cause not
# identified" shape above is precisely where a bare alert is a dead end for
# whoever reads it — this proves the top-disk-consumers measurement (stubbed
# fixture: "3583 .../bash-edit-diff" and "812 .../pytest-of-athos") actually
# reaches BOTH the permanent log AND the durable Mayor-mail body alongside
# that diagnosis, turning "cause not identified" into something actionable
# instead of requiring a human to go run `du` by hand — the whole point of
# invariant (b). Reuses Scenario I's exact setup (CRITICAL, sustain already
# 1 so this cycle confirms and mails).
reset_capture; seed_state "" ""; seed_critical_sustain 1
_vm_swap_gb() { echo "1"; }
queue_avail 2 2
main
_vm_swap_gb() { echo "7"; }   # restore default stub for later scenarios
if grep -q "top disk consumers (MB path, known scratch/cache roots):" "$LOG" 2>/dev/null && grep -q "  3583 /private/tmp/claude-501/bash-edit-diff" "$LOG" 2>/dev/null; then
  ok "main(): top-disk-consumers measurement is logged alongside the diagnosis (invariant b — not silence, not a dead end)"
else
  bad "main(): expected the top-disk-consumers block in LOG, tail: $(tail -8 "$LOG" 2>/dev/null | tr '\n' ';')"
fi
if [ "$GC_MAIL_CALLS" = "1" ]; then
  case "$GC_MAIL_LAST_BODY" in
    *"Top disk consumers measured this cycle"*"3583 /private/tmp/claude-501/bash-edit-diff"*)
      ok "main(): CRITICAL mail to Mayor includes the top-disk-consumers paragraph with the actual measured entries" ;;
    *)
      bad "main(): mail body missing the top-disk-consumers paragraph — got: $(printf '%s' "$GC_MAIL_LAST_BODY" | tr '\n' ';' | cut -c1-500)" ;;
  esac
else
  bad "main(): expected this CRITICAL cycle (sustain already 1) to confirm and mail, GC_MAIL_CALLS=$GC_MAIL_CALLS"
fi

# Scenario J — reclaim effect UNMEASURABLE (post-reclaim df read itself
# fails, e.g. a transient df hiccup): must say "could not measure", never
# silently fall back to claiming either specific cause on fabricated data
# (ga-p5q3 discipline extended to this new diagnosis).
reset_capture; seed_state "" ""; seed_critical_sustain 1
queue_avail 2   # only ONE reading queued — the post-reclaim _avail_gb call empties the queue and returns ""
main
case "$NOTIFY_LAST_MSG" in
  *"will NOT resolve"*|*"recovered"*|*"cause not identified"*) bad "main(): unmeasurable-reclaim case fabricated a specific diagnosis — got: $NOTIFY_LAST_MSG" ;;
  *"unmeasured"*) ok "main(): unmeasurable post-reclaim reading honestly says so, not a fabricated cause" ;;
  *) bad "main(): unmeasurable-reclaim notify message missing the honest-unmeasured framing — got: $NOTIFY_LAST_MSG" ;;
esac

# Scenario K (ga-ff6t9): a FRESH WARN-tier cycle (no prior state -> cooldown
# fail-open fires notify unconditionally on the first read) must NOT
# force-push. Mutation check on the fix above: force-push is reserved for the
# guaranteed-page CRITICAL tier (was_critical=1); a routine WARN notify is
# meant to keep going through notify's normal content-based routing (the
# established low-blast-radius pattern this codebase already uses for
# routine, non-emergency alerts). Without this negative control, a fix that
# accidentally force-pushed EVERY notify call (not just CRITICAL) would pass
# every other scenario in this file (none of them assert force-push is
# ABSENT) — same discipline as escalate_emergency.py's own T2 "unsanctioned
# class rejected" test.
reset_capture; seed_state "" ""; seed_critical_sustain ""
queue_avail 6 6
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "3" ] && [ -z "$NOTIFY_LAST_FORCE_PUSH" ]; then
  ok "main(): fresh WARN-tier notify (prio 3) does NOT force-push (scoped correctly to CRITICAL only)"
else
  bad "main(): WARN-tier force-push scoping regressed (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO force_push='$NOTIFY_LAST_FORCE_PUSH')"
fi

echo ""
echo "=== main(): scratchpad + transcript reap integration (ga-02pnu, ga-t1ub9) ==="
# Scenario E — BOTH new reclaim levers must actually be wired into main()'s
# reclaim step (called alongside _safe_reclaim, before the post-reclaim avail
# re-read) on EVERY cycle that reaches the reclaim step at all — regardless of
# whether the outcome ends up CRITICAL, WARN-notify, or WARN-suppressed. Reuses
# scenario A's readings (CRITICAL -> recovers to NONE).
reset_capture; seed_state "" ""
queue_avail 2 20
main
if [ "$REAP_CALLS" = "1" ] && [ "$REAP_TRANSCRIPT_CALLS" = "1" ] && [ "$REAP_LOGS_CALLS" = "1" ] && [ "$REAP_HF_CALLS" = "1" ] && [ "$REAP_GOCACHE_CALLS" = "1" ] && [ "$REAP_GO_BUILD_CALLS" = "1" ] && [ "$REAP_CODE_SIGN_CLONE_CALLS" = "1" ] && [ "$REAP_BASH_EDIT_DIFF_CALLS" = "1" ] && [ "$REAP_ORPHAN_TEST_DOLT_CALLS" = "1" ] && [ "$REAP_BACKUP_RESIDUE_CALLS" = "1" ] && [ "$REAP_BACKUP_STAGING_CALLS" = "1" ]; then
  ok "main(): _reap_dead_scratch, _reap_dead_transcripts, _reap_growing_logs, _reap_hf_cache, _reap_gocache, _reap_go_build_orphans, _reap_code_sign_clone_orphans, _reap_bash_edit_diff_orphans, _reap_orphan_test_dolt_processes, _reap_backup_residue, AND _reap_bloated_backup_staging each invoked exactly once alongside _safe_reclaim"
else
  bad "main(): expected all eleven reap levers called once, got REAP_CALLS=$REAP_CALLS REAP_TRANSCRIPT_CALLS=$REAP_TRANSCRIPT_CALLS REAP_LOGS_CALLS=$REAP_LOGS_CALLS REAP_HF_CALLS=$REAP_HF_CALLS REAP_GOCACHE_CALLS=$REAP_GOCACHE_CALLS REAP_GO_BUILD_CALLS=$REAP_GO_BUILD_CALLS REAP_CODE_SIGN_CLONE_CALLS=$REAP_CODE_SIGN_CLONE_CALLS REAP_BASH_EDIT_DIFF_CALLS=$REAP_BASH_EDIT_DIFF_CALLS REAP_ORPHAN_TEST_DOLT_CALLS=$REAP_ORPHAN_TEST_DOLT_CALLS REAP_BACKUP_RESIDUE_CALLS=$REAP_BACKUP_RESIDUE_CALLS REAP_BACKUP_STAGING_CALLS=$REAP_BACKUP_STAGING_CALLS"
fi
if [ "$REAP_LAST_ARG" = "1" ]; then
  ok "main(): CRITICAL cycle (even after reclaim recovers it to NONE) passes was_critical=1 to _reap_dead_scratch (ga-rjhfz pressure plumbing)"
else
  bad "main(): expected _reap_dead_scratch to receive was_critical=1 on a CRITICAL cycle, got REAP_LAST_ARG='$REAP_LAST_ARG'"
fi
if [ "$REAP_HF_LAST_ARG" = "1" ]; then
  ok "main(): CRITICAL cycle also passes was_critical=1 to _reap_hf_cache (wa-9eh0v)"
else
  bad "main(): expected _reap_hf_cache to receive was_critical=1 on a CRITICAL cycle, got REAP_HF_LAST_ARG='$REAP_HF_LAST_ARG'"
fi
if [ "$REAP_GOCACHE_LAST_ARG" = "1" ]; then
  ok "main(): CRITICAL cycle also passes was_critical=1 to _reap_gocache (ga-yi68q)"
else
  bad "main(): expected _reap_gocache to receive was_critical=1 on a CRITICAL cycle, got REAP_GOCACHE_LAST_ARG='$REAP_GOCACHE_LAST_ARG'"
fi
if [ "$REAP_BACKUP_STAGING_LAST_ARG" = "1" ]; then
  ok "main(): CRITICAL cycle also passes was_critical=1 to _reap_bloated_backup_staging (ga-74tts6)"
else
  bad "main(): expected _reap_bloated_backup_staging to receive was_critical=1 on a CRITICAL cycle, got REAP_BACKUP_STAGING_LAST_ARG='$REAP_BACKUP_STAGING_LAST_ARG'"
fi

# Scenario E2 (ga-rjhfz) — a cycle that is WARN, never CRITICAL, must pass
# was_critical=0 — the size-escape must not activate on ordinary WARN
# pressure. Reuses scenario C's readings (WARN both before and after).
reset_capture; seed_state "" ""
past_epoch=$(( $(date +%s) - 100 ))
seed_state "$past_epoch" 6
queue_avail 6 6
main
if [ "$REAP_LAST_ARG" = "0" ]; then
  ok "main(): non-critical WARN cycle passes was_critical=0 to _reap_dead_scratch (no size-escape)"
else
  bad "main(): expected _reap_dead_scratch to receive was_critical=0 on a WARN-only cycle, got REAP_LAST_ARG='$REAP_LAST_ARG'"
fi
if [ "$REAP_HF_CALLS" = "1" ] && [ "$REAP_HF_LAST_ARG" = "0" ]; then
  ok "main(): non-critical WARN cycle still calls _reap_hf_cache but with was_critical=0 (the CRITICAL-only gate lives INSIDE the real function, not in main()'s wiring — wa-9eh0v)"
else
  bad "main(): expected _reap_hf_cache called once with was_critical=0 on a WARN-only cycle, got REAP_HF_CALLS=$REAP_HF_CALLS REAP_HF_LAST_ARG='$REAP_HF_LAST_ARG'"
fi
if [ "$REAP_GOCACHE_CALLS" = "1" ] && [ "$REAP_GOCACHE_LAST_ARG" = "0" ]; then
  ok "main(): non-critical WARN cycle calls _reap_gocache with was_critical=0 (the WARN-vs-CRITICAL reap decision lives INSIDE the real function via _should_reap_gocache, not in main()'s wiring — ga-yi68q)"
else
  bad "main(): expected _reap_gocache called once with was_critical=0 on a WARN-only cycle, got REAP_GOCACHE_CALLS=$REAP_GOCACHE_CALLS REAP_GOCACHE_LAST_ARG='$REAP_GOCACHE_LAST_ARG'"
fi
if [ "$REAP_BACKUP_STAGING_CALLS" = "1" ] && [ "$REAP_BACKUP_STAGING_LAST_ARG" = "0" ]; then
  ok "main(): non-critical WARN cycle still calls _reap_bloated_backup_staging but with was_critical=0 (the CRITICAL-only gate lives INSIDE the real function, not in main()'s wiring — ga-74tts6)"
else
  bad "main(): expected _reap_bloated_backup_staging called once with was_critical=0 on a WARN-only cycle, got REAP_BACKUP_STAGING_CALLS=$REAP_BACKUP_STAGING_CALLS REAP_BACKUP_STAGING_LAST_ARG='$REAP_BACKUP_STAGING_LAST_ARG'"
fi

# Scenario F — a cycle that never reaches the floor at all (avail comfortably
# above warn on the FIRST read) must take the top early-return and never touch
# the scratch/transcript/hf-cache reapers — proves none of those reap calls
# got hoisted above the floor check.
VM_LOG_PRE_COUNT=$(grep -c "vm_swap_gb=" "$LOG" 2>/dev/null || echo 0)
reset_capture; seed_state "" ""
queue_avail 20
main
if [ "$REAP_CALLS" = "0" ] && [ "$REAP_TRANSCRIPT_CALLS" = "0" ] && [ "$REAP_HF_CALLS" = "0" ] && [ "$REAP_GOCACHE_CALLS" = "0" ] && [ "$REAP_GO_BUILD_CALLS" = "0" ] && [ "$REAP_CODE_SIGN_CLONE_CALLS" = "0" ] && [ "$REAP_BASH_EDIT_DIFF_CALLS" = "0" ] && [ "$REAP_ORPHAN_TEST_DOLT_CALLS" = "0" ] && [ "$REAP_BACKUP_RESIDUE_CALLS" = "0" ] && [ "$REAP_BACKUP_STAGING_CALLS" = "0" ]; then
  ok "main(): avail above floor on first read never invokes the scratch/transcript/hf-cache/gocache/go-build/code-sign-clone/bash-edit-diff/orphan-test-dolt/backup-residue/backup-staging reapers"
else
  bad "main(): expected zero scratch/transcript/hf-cache/gocache/go-build/code-sign-clone/bash-edit-diff/orphan-test-dolt/backup-residue/backup-staging reap calls when floor never breached, got REAP_CALLS=$REAP_CALLS REAP_TRANSCRIPT_CALLS=$REAP_TRANSCRIPT_CALLS REAP_HF_CALLS=$REAP_HF_CALLS REAP_GOCACHE_CALLS=$REAP_GOCACHE_CALLS REAP_GO_BUILD_CALLS=$REAP_GO_BUILD_CALLS REAP_CODE_SIGN_CLONE_CALLS=$REAP_CODE_SIGN_CLONE_CALLS REAP_BASH_EDIT_DIFF_CALLS=$REAP_BASH_EDIT_DIFF_CALLS REAP_ORPHAN_TEST_DOLT_CALLS=$REAP_ORPHAN_TEST_DOLT_CALLS REAP_BACKUP_RESIDUE_CALLS=$REAP_BACKUP_RESIDUE_CALLS REAP_BACKUP_STAGING_CALLS=$REAP_BACKUP_STAGING_CALLS"
fi
# ga-sfj3i.2: the exact case this acceptance criterion exists for — a cycle
# that never breaches ANY floor is precisely where the pre-fix guard logged
# nothing extra at all. Prove the vm_swap_gb line still fires here, by COUNT
# (not a bare grep -q, since $LOG accumulates across every scenario in this
# file and Scenario A already put one occurrence in it) — an unconditional
# line hoisted above the floor check must appear exactly once more.
VM_LOG_POST_COUNT=$(grep -c "vm_swap_gb=" "$LOG" 2>/dev/null || echo 0)
if [ "$VM_LOG_POST_COUNT" -eq $(( VM_LOG_PRE_COUNT + 1 )) ]; then
  ok "main(): vm_swap_gb still logs even when avail never breaches any floor (not silence — ga-sfj3i.2)"
else
  bad "main(): vm_swap_gb log line missing on a floor-never-breached cycle (pre=$VM_LOG_PRE_COUNT post=$VM_LOG_POST_COUNT)"
fi

# Scenario F2 (ga-dnc2m) — UNLIKE the two dead-session reapers just proven
# absent above, _reap_growing_logs must STILL run on this exact same
# comfortably-above-floor cycle — it is deliberately unconditional (see this
# file's own header note and the call site at the very top of main(), before
# the avail/class computation at all). This is the one assertion that
# actually distinguishes the 4th lever's behavior from the other three; if a
# future edit accidentally moves its call site below the floor check, this
# is what catches it.
if [ "$REAP_LOGS_CALLS" = "1" ]; then
  ok "main(): _reap_growing_logs runs even when avail never breaches the floor (unconditional, unlike the dead-session reapers)"
else
  bad "main(): _reap_growing_logs should run unconditionally every cycle, got REAP_LOGS_CALLS=$REAP_LOGS_CALLS"
fi

echo ""
echo "=== main(): Dolt resurrection wiring (ga-f4l2z) ==="
# _should_resurrect's own boundaries are proven in isolation above (pure-
# function tests). These scenarios prove main() actually WIRES to it
# correctly — the real bug shape (disk already fine, Dolt just never came
# back) plus the three cases that must NEVER trigger a restart attempt.

# Scenario L — the common real-world shape: Dolt confirmed down (probe_rc=1)
# + disk comfortably NONE on the FIRST read (20GB, no reclaim needed at all).
# Must call _resurrect_dolt with the correct avail/class args, from the same
# fast path that used to return silently before ga-f4l2z.
reset_capture; seed_state "" ""
RESURRECT_PROBE_RC=1
queue_avail 20
main
if [ "$RESURRECT_CALLS" = "1" ] && [ "$RESURRECT_LAST_AVAIL" = "20" ] && [ "$RESURRECT_LAST_CLASS" = "NONE" ]; then
  ok "main(): confirmed-down + class=NONE (common case: disk already fine) calls _resurrect_dolt(avail=20, class=NONE)"
else
  bad "main(): expected _resurrect_dolt(20, NONE) once, got CALLS=$RESURRECT_CALLS avail=$RESURRECT_LAST_AVAIL class=$RESURRECT_LAST_CLASS"
fi

# Scenario M — Dolt confirmed down + disk WARN (6GB both readings) — WARN is
# explicitly permitted by _should_resurrect, not just NONE.
reset_capture
past_epoch=$(( $(date +%s) - 100 ))
seed_state "$past_epoch" 6
RESURRECT_PROBE_RC=1
queue_avail 6 6
main
if [ "$RESURRECT_CALLS" = "1" ] && [ "$RESURRECT_LAST_CLASS" = "WARN" ]; then
  ok "main(): confirmed-down + class=WARN calls _resurrect_dolt"
else
  bad "main(): expected _resurrect_dolt once with class=WARN, got CALLS=$RESURRECT_CALLS class=$RESURRECT_LAST_CLASS"
fi

# Scenario N — Dolt confirmed down + disk CRITICAL (2GB pre-reclaim) — must
# NEVER resurrect, the exact crash-loop risk ga-f4l2z exists to avoid, even
# though Dolt is confirmed down. Uses Scenario A's readings (2 -> 20) to also
# prove the check keys off the PRE-reclaim class, not a same-cycle recovery.
reset_capture; seed_critical_sustain ""
RESURRECT_PROBE_RC=1
queue_avail 2 20
main
if [ "$RESURRECT_CALLS" = "0" ]; then
  ok "main(): confirmed-down + class=CRITICAL (even if reclaim recovers it same-cycle) never resurrects (crash-loop guard)"
else
  bad "main(): CRITICAL disk should never trigger resurrection, got RESURRECT_CALLS=$RESURRECT_CALLS"
fi

# Scenario O — Dolt healthy (probe_rc=0) — never resurrects, regardless of
# disk class (nothing to fix).
reset_capture
RESURRECT_PROBE_RC=0
queue_avail 20
main
if [ "$RESURRECT_CALLS" = "0" ]; then
  ok "main(): healthy Dolt (probe_rc=0) never resurrects"
else
  bad "main(): healthy Dolt should never trigger resurrection, got RESURRECT_CALLS=$RESURRECT_CALLS"
fi

# Scenario P — probe inconclusive (probe_rc=2, unknown/transient e.g. a CPU
# burst) — must NEVER resurrect; only a CONFIRMED outage may trigger a
# restart attempt.
reset_capture
RESURRECT_PROBE_RC=2
queue_avail 20
main
if [ "$RESURRECT_CALLS" = "0" ]; then
  ok "main(): inconclusive probe (rc=2) never resurrects (not a confirmed outage)"
else
  bad "main(): inconclusive probe should never trigger resurrection, got RESURRECT_CALLS=$RESURRECT_CALLS"
fi

# Scenario Q — disk UNKNOWN (df unreadable) — must NEVER resurrect, even if
# somehow confirmed-down; an unmeasurable floor is never "safe" to restart
# into (ga-p5q3 discipline, same as _should_resurrect's own UNKNOWN branch).
reset_capture
RESURRECT_PROBE_RC=1
queue_avail ""
main
if [ "$RESURRECT_CALLS" = "0" ]; then
  ok "main(): disk class=UNKNOWN never resurrects, even with a confirmed-down probe (unmeasurable-floor guard)"
else
  bad "main(): UNKNOWN disk class should never trigger resurrection, got RESURRECT_CALLS=$RESURRECT_CALLS"
fi
RESURRECT_PROBE_RC=0   # restore safe default for any scenario added after this point

echo ""
echo "=== main(): disk-growth photo wiring (ga-ond0fa) ==="
# The photo/baseline functions are stubbed in this section (see their stubs above:
# no real scans in main() scenarios), so these prove main()'s WIRING — WHEN it
# calls them and with WHAT — not the scan itself (proven by the unit section).

# Scenario R — a CRITICAL cycle takes the episode photo exactly once, with the
# PRE-reclaim class/avail, BEFORE any reclaim lever has run. The counter snapshot
# taken inside the stub at call time is 0/0/0/0/0; REAP_CALLS == 1 afterwards
# proves the levers did run later in the same cycle (so 0 means "before", not
# "never ran"). The baseline is NOT refreshed on a CRITICAL cycle, even though
# reclaim recovers avail to 20GB (only the pre-reclaim-NONE path may refresh it).
reset_capture; seed_state "" ""; seed_critical_sustain ""
queue_avail 2 20
main
if [ "$GROWTH_PHOTO_CALLS" = "1" ] && [ "$GROWTH_PHOTO_LAST_CLASS" = "CRITICAL" ] && [ "$GROWTH_PHOTO_LAST_AVAIL" = "2" ] \
   && [ "$GROWTH_PHOTO_REAP_AT_CALL" = "0/0/0/0/0" ] && [ "$REAP_CALLS" = "1" ] && [ "$GROWTH_BASELINE_CALLS" = "0" ]; then
  ok "main(): a CRITICAL cycle photographs growth ONCE, with the pre-reclaim class/avail, BEFORE any reclaim lever; no baseline refresh"
else
  bad "main(): CRITICAL photo wiring wrong (calls=$GROWTH_PHOTO_CALLS class=$GROWTH_PHOTO_LAST_CLASS avail=$GROWTH_PHOTO_LAST_AVAIL reaped_at_call=$GROWTH_PHOTO_REAP_AT_CALL reap_calls_after=$REAP_CALLS baseline_calls=$GROWTH_BASELINE_CALLS)"
fi

# Scenario S — a WARN cycle photographs too (the first WARN of an episode), also
# before the levers.
reset_capture; seed_state "" ""; seed_critical_sustain ""
queue_avail 6 6
main
if [ "$GROWTH_PHOTO_CALLS" = "1" ] && [ "$GROWTH_PHOTO_LAST_CLASS" = "WARN" ] && [ "$GROWTH_PHOTO_REAP_AT_CALL" = "0/0/0/0/0" ]; then
  ok "main(): a WARN cycle photographs growth before the reclaim levers (class=WARN)"
else
  bad "main(): WARN photo wiring wrong (calls=$GROWTH_PHOTO_CALLS class=$GROWTH_PHOTO_LAST_CLASS reaped_at_call=$GROWTH_PHOTO_REAP_AT_CALL)"
fi

# Scenario T — a healthy (pre-reclaim NONE) cycle refreshes the baseline, takes no
# episode photo, and ENDS the episode (a leftover episode file is removed, so the
# next WARN/CRITICAL earns a fresh photo).
reset_capture; seed_state "" ""; seed_critical_sustain ""
printf 'CRITICAL\n/some/old/photo.txt\n' > "$(_growth_episode_file)"
queue_avail 20
main
if [ "$GROWTH_BASELINE_CALLS" = "1" ] && [ "$GROWTH_PHOTO_CALLS" = "0" ] && [ ! -e "$(_growth_episode_file)" ]; then
  ok "main(): a healthy cycle refreshes the baseline, takes no photo, and ends the growth episode (episode file cleared)"
else
  bad "main(): healthy-cycle wiring wrong (baseline_calls=$GROWTH_BASELINE_CALLS photo_calls=$GROWTH_PHOTO_CALLS episode_file_exists=$([ -e "$(_growth_episode_file)" ] && echo yes || echo no))"
fi

# Scenario U — df unreadable (UNKNOWN): neither the photo nor the baseline runs
# (main returns before either; an unmeasurable floor is not an episode).
reset_capture; seed_state "" ""; seed_critical_sustain ""
queue_avail ""
main
if [ "$GROWTH_PHOTO_CALLS" = "0" ] && [ "$GROWTH_BASELINE_CALLS" = "0" ]; then
  ok "main(): class=UNKNOWN takes neither a photo nor a baseline"
else
  bad "main(): UNKNOWN cycle must not scan (photo_calls=$GROWTH_PHOTO_CALLS baseline_calls=$GROWTH_BASELINE_CALLS)"
fi

# Scenario V — the Mayor CRITICAL mail carries THIS episode's photo (taken by an
# EARLIER cycle: each cycle is its own process, so the mail cannot rely on
# in-memory state). Seed the episode file + a canned photo, then run the 2nd
# consecutive CRITICAL cycle (sustain 1 -> 2, mails).
CANNED_PHOTO="$STATE_TMP/disk-growth-canned.txt"
printf '%s\n' "# dolt-disk-floor-guard disk-growth photo (ga-ond0fa)" "TS	1" \
  "# ==== disk-growth report (ga-ond0fa) — class=CRITICAL avail=2GB at 2026-09-25 01:51:00 ====" \
  "# Growth since the last OK photo (17 min old; entries that grew >= 50MB, MB path):" \
  "#   +7000MB  /private/tmp/claude-501/CANNED-CULPRIT  (now 7100MB, was 100MB)" > "$CANNED_PHOTO"
reset_capture; seed_state "" ""; seed_critical_sustain 1
printf 'CRITICAL\n%s\n' "$CANNED_PHOTO" > "$(_growth_episode_file)"
queue_avail 2 20
main
case "$GC_MAIL_LAST_BODY" in
  *"WHAT GREW (ga-ond0fa)"*"Photo file: $CANNED_PHOTO"*"+7000MB  /private/tmp/claude-501/CANNED-CULPRIT"*)
    ok "main(): the Mayor CRITICAL mail names the episode's growth photo and its top grower (WHAT GREW section)" ;;
  *) bad "main(): mail body missing the growth section/photo path/culprit: $(printf '%s' "$GC_MAIL_LAST_BODY" | tail -c 500)" ;;
esac

# Scenario W — same mail with NO photo this episode: says so, never silent, never
# a stale photo.
reset_capture; seed_state "" ""; seed_critical_sustain 1
queue_avail 2 20
main
case "$GC_MAIL_LAST_BODY" in
  *"WHAT GREW (ga-ond0fa)"*"no disk-growth photo recorded for this episode"*) ok "main(): with no photo this episode the mail says so explicitly instead of omitting the section" ;;
  *) bad "main(): mail body should state that no growth photo exists: $(printf '%s' "$GC_MAIL_LAST_BODY" | tail -c 400)" ;;
esac

rm -rf "$STATE_TMP"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
