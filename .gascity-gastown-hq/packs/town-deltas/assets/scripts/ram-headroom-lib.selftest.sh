#!/usr/bin/env bash
# ram-headroom-lib.selftest.sh (ga-1p1i5jr.14) — ram-headroom-lib.sh: the floors, the three states, and the reading of `memory_pressure` + `sysctl hw.memsize` in the shape
# macOS prints. Hermetic: uname/sysctl/memory_pressure are FAKES first on PATH (a sysctl key nobody modelled is recorded and fails). RAM_LIB_UNDER_TEST swaps the lib.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${RAM_LIB_UNDER_TEST:-$HERE/ram-headroom-lib.sh}"
W="$(mktemp -d "${TMPDIR:-/tmp}/ram-lib-st.XXXXXX")"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1: expected '$2', got '$3'"; fi; }
mkdir -p "$W/bin" "$W/fake"
printf '%s\n' '#!/bin/sh' 'cat "$FAKE/uname"' > "$W/bin/uname"
printf '%s\n' '#!/bin/sh' 'if [ "$*" = "-n hw.memsize" ]; then cat "$FAKE/memsize"; else echo "sysctl $*" >> "$FAKE/unmodelled"; exit 2; fi' > "$W/bin/sysctl"
printf '%s\n' '#!/bin/sh' 'cat "$FAKE/mp"' > "$W/bin/memory_pressure"
chmod +x "$W/bin/uname" "$W/bin/sysctl" "$W/bin/memory_pressure"
# run <snippet> [VAR=val...] — the snippet runs in a fresh POSIX sh that sourced the lib, with the fakes first on PATH
run() { local s="$1"; shift; env PATH="$W/bin:/usr/bin:/bin" FAKE="$W/fake" "$@" sh -c ". \"$LIB\"; $s" 2>&1; }
# mp <pct> — memory_pressure as macOS prints it (the line the reader keys on is the LAST one, after the page counts)
mp() { printf '%s\n' 'The system has 17179869184 (1048576 pages with a page size of 16384).' '' 'Stats: ' 'Pages free: 7340 ' 'Pages purgeable: 34410 ' 'Pages active: 380145 ' 'Pages inactive: 358761 ' '' 'System-wide memory free percentage: '"$1"'%' > "$W/fake/mp"; }
darwin() { echo Darwin > "$W/fake/uname"; echo 17179869184 > "$W/fake/memsize"; mp 54; }
avail() { run 'ram_avail_mb; echo " rc=$?"' "$@"; }

[ -r "$LIB" ] || { echo "FAIL: $LIB does not exist"; echo "ram-headroom-lib selftest: 0 passed, 1 failed"; exit 1; }
eq "sourcing prints nothing and reads nothing" "" "$(run ':')"
# the floors: 2048 to START memory-hungry work, 1024 = the biggest job the mini may run; junk, 0, 08 and 10+ digits fall back to the default
fl() { run 'echo "$RAM_NEW_WORK_MIN_MB/$RAM_JOB_MAX_MB"' "$@"; }
eq "default floors"                      "2048/1024" "$(fl X=1)"
eq "junk floors fall back"               "2048/1024" "$(fl RAM_NEW_WORK_MIN_MB=junk RAM_JOB_MAX_MB=)"
eq "a floor of 0 or 08 is the default"   "2048/1024" "$(fl RAM_NEW_WORK_MIN_MB=0 RAM_JOB_MAX_MB=08)"
eq "10 digits fall back"                 "2048/1024" "$(fl RAM_NEW_WORK_MIN_MB=1234567890 RAM_JOB_MAX_MB=1234567890)"
# the one comparison: ok | low | unknown, and `[` that could not compare is never "plenty"
sto() { run "ram_state_of $1 $2"; }
eq "plenty is ok"                        ok      "$(sto 8000 2048)"
eq "exactly the floor is ok"             ok      "$(sto 2048 2048)"
eq "one MB under is low"                 low     "$(sto 2047 2048)"
eq "0 MB is a reading (low)"             low     "$(sto 0 2048)"
eq "non-numeric reading is unknown"      unknown "$(sto abc 2048)"
eq "empty reading is unknown"            unknown "$(sto "''" 2048)"
eq "negative reading is unknown"         unknown "$(sto -5 2048)"
eq "negative floor is unknown"           unknown "$(sto 8000 -5)"
eq "empty floor is unknown"              unknown "$(sto 8000 "''")"
eq "junk floor is unknown"               unknown "$(sto 8000 12x)"
eq "20-digit reading is unknown (rc 2)"  unknown "$(sto 99999999999999999999 2048)"
eq "20-digit floor is unknown (rc 2)"    unknown "$(sto 8000 99999999999999999999)"
eq "kill switch makes every state ok"    ok      "$(run 'ram_state_of 0 2048' RAM_HEADROOM_ENABLED=0)"
eq "set -e safe on a low reading"        alive:low "$(env PATH="$W/bin:/usr/bin:/bin" sh -ec ". \"$LIB\"; x=\$(ram_state_of 1 2048); echo alive:\$x")"
command -v dash >/dev/null 2>&1 && eq "works under dash" low "$(env PATH="$W/bin:/usr/bin:/bin" dash -c ". \"$LIB\"; ram_state_of 1 2048")"
# the host: Darwin is the only kind with a reading; an unreadable uname is "unknown", never "other" (not applicable)
hk() { echo "$1" > "$W/fake/uname"; run 'ram_host_kind'; }
eq "Darwin"                              darwin  "$(hk Darwin)"
eq "Linux is another host"               other   "$(hk Linux)"
rm -f "$W/fake/uname"; eq "uname that fails is unknown" unknown "$(run 'ram_host_kind')"
# the reading: free% of the machine, in MB. 54% of 16384 MB = 8847
darwin
eq "54% of 16 GB"                        "8847 rc=0" "$(avail)"
mp 0;   eq "0% is a reading, not a failure" "0 rc=0"     "$(avail)"
mp 100; eq "100%"                        "16384 rc=0" "$(avail)"
darwin; rm -f "$W/fake/mp";            eq "memory_pressure that fails"    " rc=1" "$(avail)"
darwin; printf 'The system has 17179869184 (1048576 pages)\n' > "$W/fake/mp"; eq "no free-percentage line" " rc=1" "$(avail)"
darwin; printf 'System-wide memory free percentage: 54\n' > "$W/fake/mp";      eq "a percentage without the % sign" " rc=1" "$(avail)"
mp 101; eq "101% is not a percentage"    " rc=1" "$(avail)"
mp 08;  eq "08% (octal bait) is no shape macOS prints" " rc=1" "$(avail)"
darwin; echo 99999999999999999999 > "$W/fake/memsize"; eq "20-digit hw.memsize" " rc=1" "$(avail)"
darwin; echo 017179869184 > "$W/fake/memsize";         eq "hw.memsize with a leading zero" " rc=1" "$(avail)"
darwin; rm -f "$W/fake/memsize";       eq "hw.memsize that fails"         " rc=1" "$(avail)"
darwin; echo notanumber > "$W/fake/memsize"; eq "hw.memsize garbage"       " rc=1" "$(avail)"
darwin; echo 0 > "$W/fake/memsize";    eq "hw.memsize 0 is not a machine" " rc=1" "$(avail)"
darwin; echo 16384 > "$W/fake/memsize"; eq "hw.memsize in MB would read 0 MB free: unreadable" " rc=1" "$(avail)"
darwin; echo Linux > "$W/fake/uname";  eq "no reading on another host"    " rc=1" "$(avail)"
darwin; rm -f "$W/fake/uname";         eq "no reading when uname fails"   " rc=1" "$(avail)"
eq "no sysctl key but hw.memsize was asked" "no" "$([ -e "$W/fake/unmodelled" ] && echo yes || echo no)"
# the test seam: a number pins the reading (any host), anything else is "unreadable" so the unknown path is testable
darwin; echo Linux > "$W/fake/uname"
eq "override pins the reading"           "1234 rc=0" "$(avail RAM_AVAIL_OVERRIDE_MB=1234)"
eq "override junk is unreadable"         " rc=1"      "$(avail RAM_AVAIL_OVERRIDE_MB=abc)"
eq "override of 10 digits is unreadable" " rc=1"      "$(avail RAM_AVAIL_OVERRIDE_MB=1234567890)"
echo "ram-headroom-lib selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
