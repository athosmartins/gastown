#!/usr/bin/env bash
# heavy-guard-ram.selftest.sh (ga-1p1i5jr.14) — the RAM class of heavy-guard.sh: a python/node/duckdb step, or one that declares --ram-mb, is refused
# on the mini (rc 75, "run it on the Hetzner node") when the free RAM is short or the job is >= RAM_JOB_MAX_MB, and unreadable RAM is 76.
# Hermetic: the real guard + the real libs; the disk reading is pinned (DISK_FREE_OVERRIDE_MB), uname/sysctl/memory_pressure and the interpreters are
# harmless fakes first on PATH, the log lives in a scratch dir. HG_UNDER_TEST swaps the guard (the mutant driver).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HG_UNDER_TEST:-$HERE/heavy-guard.sh}"
DLIB="$HERE/../packs/town-deltas/assets/scripts/disk-headroom-lib.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/hg-ram-st.XXXXXX")"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
mkdir -p "$W/bin" "$W/fake" "$W/city/.gc/logs"
export GC_CITY_PATH="$W/city" HEAVY_GUARD_LOG="$W/city/.gc/logs/heavy-guard.log" FAKE="$W/fake" RAN="$W/ran"
unset RAM_AVAIL_OVERRIDE_MB RAM_HEADROOM_ENABLED RAM_NEW_WORK_MIN_MB RAM_JOB_MAX_MB HEAVY_GUARD_RAM_LIB
# fakes: uname + the macOS memory readers (strict: an unmodelled sysctl key fails), and interpreters that only record that they ran
printf '%s\n' '#!/bin/sh' 'cat "$FAKE/uname"' > "$W/bin/uname"
printf '%s\n' '#!/bin/sh' 'if [ "$*" = "-n hw.memsize" ]; then echo 17179869184; else exit 2; fi' > "$W/bin/sysctl"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "The system has 17179869184 (1048576 pages with a page size of 16384)." "" "System-wide memory free percentage: $(cat "$FAKE/pct")%"' > "$W/bin/memory_pressure"
for i in python3 node duckdb; do printf '%s\n' '#!/bin/sh' 'echo "$0 $*" >> "$RAN"' > "$W/bin/$i"; done
chmod +x "$W/bin/"*
echo Darwin > "$W/fake/uname"; echo 54 > "$W/fake/pct"
# g <ENV=val...> -- <guard args...> : runs the guard on a 20 GB disk, the fakes first on PATH; sets RC, ERR (stderr) and RANIT (did a fake interpreter run)
g() {
  local e=(X=1); while [ "$1" != "--" ]; do e+=("$1"); shift; done; shift
  rm -f "$RAN"; : > "$HEAVY_GUARD_LOG"
  env "${e[@]}" PATH="$W/bin:$PATH" DISK_FREE_OVERRIDE_MB=20000 HEAVY_GUARD_LIB="$DLIB" "$GUARD" "$@" > "$W/out" 2> "$W/err"; RC=$?
  ERR="$(cat "$W/err")"; RANIT=no; [ -e "$RAN" ] && RANIT=yes
  return 0
}
want() { # want <desc> <rc> <ran yes|no>
  if [ "$RC" = "$2" ] && [ "$RANIT" = "$3" ]; then ok; else bad "$1: expected rc=$2 ran=$3, got rc=$RC ran=$RANIT ($(printf '%s' "$ERR" | head -c 200))"; fi
}
LOW=RAM_AVAIL_OVERRIDE_MB=1000; PLENTY=RAM_AVAIL_OVERRIDE_MB=8000

# which commands are in the class: each is REFUSED on a short RAM (so it never runs) and runs on a roomy one
for c in "python3 x.py" "/opt/homebrew/bin/python3.12 -I x.py" ".venv/bin/python x.py" "env PYTHONPATH=. python3 x.py" "node build.js" "nodejs b.js" "duckdb a.db" "sh -c 'python3 x.py'" "bash -c 'node y.js'"; do
  g "$LOW" -- --what batch -- $c;  want "in the class, short RAM: $c" 75 no
done
for c in "python3 x.py" "node build.js" "duckdb a.db" "env PYTHONPATH=. python3 x.py"; do
  g "$PLENTY" -- --what batch -- $c; want "in the class, roomy RAM: $c" 0 yes
done
# and these are NOT in the class: never a RAM refusal, even at 1000 MB
for c in "echo hello" "git --version python3" "bash x.sh" "pythonista x" "ls /usr/lib/python-x"; do
  g "$LOW" -- --what batch -- $c; [ "$RC" != 75 ] && [ "$RC" != 76 ] && ok || bad "not in the class, refused: $c (rc=$RC)"
done
g "$LOW" -- --what selftest-x -- python3 y.py;    want "a selftest step keeps its own rules (no RAM check)" 0 yes
g "$LOW" -- --what go-test -- python3 y.py;       want "a Go step keeps its own rules (no RAM check)" 0 yes
g "$LOW" -- --check --what pre-push --ram-mb 5000;  want "a push keeps its own rules (no RAM check)" 0 no
# the refusal says where to go and is logged; it is 75, never the 96..99 band
g "$LOW" -- --what lidar -- python3 build.py
case "$ERR" in *Hetzner*REFUSED*|*REFUSED*Hetzner*) ok ;; *) bad "refusal must name the Hetzner node: $ERR" ;; esac
grep -q "REFUSED what='lidar' class=ram free_mb=1000 need_mb=2048 rc=75" "$HEAVY_GUARD_LOG" && ok || bad "refusal not in the log: $(cat "$HEAVY_GUARD_LOG")"
# --ram-mb: a declared size. >= RAM_JOB_MAX_MB (1024) goes to the node whatever the RAM; below it needs floor (2048) + the declared MB
g "$PLENTY" -- --what big --ram-mb 2100 -- true;  want "declared 2100 MB: refused with 20 GB of RAM" 75 no
grep -q "REFUSED what='big' class=ram declared_mb=2100 max_mb=1024 rc=75" "$HEAVY_GUARD_LOG" && ok || bad "declared refusal not in the log: $(cat "$HEAVY_GUARD_LOG")"
g "$PLENTY" -- --ram-mb 1024 -- true;             want "declared 1024 MB is the line: refused" 75 no
g "$PLENTY" -- --ram-mb 1023 -- true;             want "declared 1023 MB with room: runs" 0 no
g RAM_AVAIL_OVERRIDE_MB=3047 -- --ram-mb 1000 -- true;  want "1000 declared needs 3048: 3047 refused" 75 no
g RAM_AVAIL_OVERRIDE_MB=3048 -- --ram-mb 1000 -- true;  want "1000 declared needs 3048: 3048 runs" 0 no
g "$LOW" -- --ram-mb 0 -- python3 x.py;           want "--ram-mb 0 is the explicit opt-out" 0 yes
g RAM_AVAIL_OVERRIDE_MB=2057 -- --ram-mb 010 -- true;   want "--ram-mb 010 is ten, not octal eight (needs 2058)" 75 no
g "$PLENTY" -- --ram-mb 08 -- true;                want "--ram-mb 08 is a number, not an octal error" 0 no
g "$PLENTY" -- --ram-mb abc -- true;              want "--ram-mb abc is a usage error" 64 no
g "$PLENTY" -- --ram-mb 1234567890 -- true;       want "--ram-mb past 9 digits is a usage error" 64 no
g RAM_AVAIL_OVERRIDE_MB=3000 -- --check --ram-mb 500;   want "--check with a declared size and room" 0 no
g RAM_AVAIL_OVERRIDE_MB=2000 -- --check --ram-mb 500;   want "--check with a declared size and no room" 75 no
g "$LOW" -- --check --what python3;               want "--check without --ram-mb has no command to classify" 0 no
# three states: unreadable RAM, an absent lib or an unreadable host is 76 for a class step, and changes nothing for any other
g RAM_AVAIL_OVERRIDE_MB=abc -- --what b -- python3 x.py;   want "unreadable RAM, class step" 76 no
g RAM_AVAIL_OVERRIDE_MB=abc -- --what b -- echo hi;        want "unreadable RAM, other step" 0 no
g HEAVY_GUARD_RAM_LIB=/nonexistent/ram.sh -- --what b -- python3 x.py;  want "RAM lib absent, class step" 76 no
g HEAVY_GUARD_RAM_LIB=/nonexistent/ram.sh -- --what b -- echo hi;       want "RAM lib absent, other step" 0 no
rm -f "$W/fake/uname"; g "$PLENTY" -- --what b -- python3 x.py;  want "uname that fails: host unknown" 76 no
echo Linux > "$W/fake/uname"; g "$LOW" -- --what b -- python3 x.py; want "Linux (the node): nothing to refuse" 0 yes
echo Darwin > "$W/fake/uname"
# the kill switch is visible; the end-to-end reading (memory_pressure x hw.memsize, no override) decides too
g "$LOW" RAM_HEADROOM_ENABLED=0 -- --what b -- python3 x.py;  want "kill switch lets it through" 0 yes
case "$ERR" in *"RAM check bypassed"*) ok ;; *) bad "kill switch must say so on stderr: $ERR" ;; esac
grep -q "BYPASS what='b' class=ram" "$HEAVY_GUARD_LOG" && ok || bad "bypass not in the log"
echo 5 > "$W/fake/pct";  g X=1 -- --what b -- python3 x.py;  want "end to end: 5% free of 16 GB = 819 MB" 75 no
echo 54 > "$W/fake/pct"; g X=1 -- --what b -- python3 x.py;  want "end to end: 54% free = 8847 MB" 0 yes
echo "heavy-guard-ram selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
