#!/usr/bin/env bash
# heavy-guard.selftest.sh (ga-vln2py) — disk-headroom-lib.sh and heavy-guard.sh.
# Hermetic: the reading is pinned with DISK_FREE_OVERRIDE_MB (or a fake `df` on PATH for the wait path), the
# refusal log lives in a scratch dir, and nothing here touches the real disk or the real city.
# The case functions run against the REAL files and then against MUTANTS of them: a mutant that survives means
# the cases would not notice that regression (a selftest that only passes proves nothing).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_LIB="$HERE/../packs/town-deltas/assets/scripts/disk-headroom-lib.sh"
REAL_GUARD="$HERE/heavy-guard.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/heavy-guard-st.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
check() { # check <desc> <expected-rc> <actual-rc>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected rc $2, got $3"; fi
}
export GC_CITY_PATH="$W/city"; mkdir -p "$GC_CITY_PATH/.gc/logs"
export HEAVY_GUARD_LOG="$W/city/.gc/logs/heavy-guard.log"
unset DISK_FREE_OVERRIDE_MB DISK_HEADROOM_PATH DISK_HEADROOM_ENABLED DISK_NEW_WORK_MIN_MB DISK_HEAVY_MIN_MB HEAVY_GUARD_POLL_SECS

# ── lib cases: lib_cases <lib> ───────────────────────────────────────────────────────────────────────────────
lib_cases() {
  local lib="$1" s
  st() { ( DISK_FREE_OVERRIDE_MB="$1" sh -c '. "$1"; disk_headroom_state "$2"' _ "$lib" "$3" ); }
  [ "$(st 8000 x 5120)" = ok ]       || bad "lib: 8000 MB vs floor 5120 should be ok"
  [ "$(st 3000 x 5120)" = low ]      || bad "lib: 3000 MB vs floor 5120 should be low"
  [ "$(st 5120 x 5120)" = ok ]       || bad "lib: exactly the floor is ok (the floor is a minimum, not a margin)"
  [ "$(st 5119 x 5120)" = low ]      || bad "lib: one MB under the floor is low"
  [ "$(st 0 x 5120)" = low ]         || bad "lib: a reading of 0 MB is a reading (low), not 'unreadable'"
  [ "$(st abc x 5120)" = unknown ]   || bad "lib: a non-numeric reading must be unknown, never ok"
  [ "$(st 8000 x '')" = ok ]         || bad "lib: an empty floor argument means the default (5120), 8000 is ok"
  [ "$(st 8000 x 12x)" = unknown ]   || bad "lib: a floor that is not a number must be unknown"
  # a digit string past int64 is a number `[ -lt ]` cannot compare (rc 2): that is "unknown", never the else-arm "ok"
  [ "$(st 8000 x 99999999999999999999)" = unknown ] || bad "lib: a 20-digit floor must be unknown (the comparison could not be made)"
  [ "$(st 99999999999999999999 x 5120)" = unknown ] || bad "lib: a 20-digit reading must be unknown, not ok"
  s="$( DISK_FREE_OVERRIDE_MB=99999999999999999999 sh -c '. "$1"; disk_free_mb; echo "rc=$?"' _ "$lib" )"
  [ "$s" = "rc=1" ]                  || bad "lib: disk_free_mb of a 20-digit reading must print nothing and return 1 (got '$s')"
  s="$( DISK_FREE_OVERRIDE_MB=1234567890 sh -c '. "$1"; disk_free_mb; echo "rc=$?"' _ "$lib" )"
  [ "$s" = "rc=1" ]                  || bad "lib: disk_free_mb refuses a reading of more than 9 digits (got '$s')"
  s="$( DISK_FREE_OVERRIDE_MB=123456789 sh -c '. "$1"; disk_free_mb' _ "$lib" )"
  [ "$s" = 123456789 ]               || bad "lib: a 9-digit reading is still a reading (got '$s')"
  s="$( DISK_HEAVY_MIN_MB=99999999999999999999 DISK_NEW_WORK_MIN_MB=1234567890 sh -c '. "$1"; echo "$DISK_NEW_WORK_MIN_MB/$DISK_HEAVY_MIN_MB"' _ "$lib" )"
  [ "$s" = "5120/6144" ]             || bad "lib: a floor of more than 9 digits in the env must fall back to the default (got '$s')"
  s="$( DISK_HEADROOM_ENABLED=0 sh -c '. "$1"; disk_state_of 1 99999' _ "$lib" )"
  [ "$s" = ok ]                      || bad "lib: disk_state_of honours the kill switch (got '$s')"
  s="$( DISK_HEADROOM_PATH=/nonexistent-dir-vln2py sh -c '. "$1"; disk_headroom_state 5120' _ "$lib" )"
  [ "$s" = unknown ]                 || bad "lib: df failing on the path must be unknown (got '$s')"
  s="$( DISK_HEADROOM_PATH=/ sh -c '. "$1"; disk_headroom_state 1' _ "$lib" )"
  [ "$s" = ok ]                      || bad "lib: a real df of / against a 1 MB floor must be ok (got '$s')"
  s="$( DISK_HEADROOM_ENABLED=0 DISK_FREE_OVERRIDE_MB=0 sh -c '. "$1"; disk_headroom_state 5120' _ "$lib" )"
  [ "$s" = ok ]                      || bad "lib: the kill switch must make every state ok (got '$s')"
  s="$( DISK_FREE_OVERRIDE_MB=100 sh -c '. "$1"; disk_headroom_state' _ "$lib" )"
  [ "$s" = low ]                     || bad "lib: no argument defaults to the new-work floor, 100 MB is low (got '$s')"
  s="$( DISK_NEW_WORK_MIN_MB=garbage DISK_HEAVY_MIN_MB= sh -c '. "$1"; echo "$DISK_NEW_WORK_MIN_MB/$DISK_HEAVY_MIN_MB"' _ "$lib" )"
  [ "$s" = "5120/6144" ]             || bad "lib: garbage in the floor env must fall back to 5120/6144 (got '$s')"
  # the reader must not die under set -e when the state is not ok (callers run it inside $(...) with set -e on)
  s="$( DISK_FREE_OVERRIDE_MB=1 sh -ec '. "$1"; x=$(disk_headroom_state 5120); echo "alive:$x"' _ "$lib" )"
  [ "$s" = "alive:low" ]             || bad "lib: set -e safety (got '$s')"
  if command -v dash >/dev/null 2>&1; then
    s="$( DISK_FREE_OVERRIDE_MB=1 dash -c '. "$1"; disk_headroom_state 5120' _ "$lib" )"
    [ "$s" = low ] || bad "lib: must work under dash (POSIX sh), got '$s'"
    s="$( DISK_FREE_OVERRIDE_MB=8000 dash -c '. "$1"; disk_headroom_state 99999999999999999999' _ "$lib" )"
    [ "$s" = unknown ] || bad "lib: dash says 'Illegal number' (rc 2) on a 20-digit floor: must be unknown, got '$s'"
  fi
}

# ── guard cases: guard_cases <guard> <lib> ───────────────────────────────────────────────────────────────────
guard_cases() {
  local g="$1" lib="$2" rc out
  run() { HEAVY_GUARD_LIB="$lib" "$g" "$@"; }
  rm -f "$W/ran"; : > "$HEAVY_GUARD_LOG"
  out="$(DISK_FREE_OVERRIDE_MB=20000 run --what t -- sh -c 'echo hello; touch "$1"; exit 7' _ "$W/ran" 2>"$W/err")"; rc=$?
  check "guard ok runs the command and propagates its rc" 7 "$rc"
  [ "$out" = hello ] && [ -f "$W/ran" ] || bad "guard ok: the command must have run and printed (out='$out')"
  rm -f "$W/ran"
  DISK_FREE_OVERRIDE_MB=3000 run --what t -- sh -c 'touch "$1"' _ "$W/ran" 2>"$W/err"; rc=$?
  check "guard low refuses with 75" 75 "$rc"
  [ ! -e "$W/ran" ] || bad "guard low: the command RAN on a low disk"
  grep -q 'REFUSED' "$W/err" && grep -q 'rc 75' "$W/err" || bad "guard low: stderr must say REFUSED and rc 75"
  grep -q "REFUSED what='t' free_mb=3000 min_mb=6144 rc=75" "$HEAVY_GUARD_LOG" || bad "guard low: refusal not in the log ($(cat "$HEAVY_GUARD_LOG"))"
  DISK_FREE_OVERRIDE_MB=notanumber run --what t -- sh -c 'touch "$1"' _ "$W/ran" 2>"$W/err"; rc=$?
  check "guard unknown refuses with 76" 76 "$rc"
  [ ! -e "$W/ran" ] || bad "guard unknown: the command RAN with no reading of the disk"
  grep -q 'could not be read' "$W/err" || bad "guard unknown: stderr must say the disk could not be read"
  # (the exact 75/76 checks above are also what keeps a refusal out of mbp-run's 96..99 "run it local" band)
  DISK_FREE_OVERRIDE_MB=20000 run --check 2>/dev/null; rc=$?;  check "--check ok" 0 "$rc"
  DISK_FREE_OVERRIDE_MB=3000 run --check 2>/dev/null; rc=$?;  check "--check low" 75 "$rc"
  DISK_FREE_OVERRIDE_MB=x run --check 2>/dev/null; rc=$?;     check "--check unknown" 76 "$rc"
  DISK_FREE_OVERRIDE_MB=4000 run --min-free-mb 3000 --check 2>/dev/null; rc=$?;  check "custom floor below the reading" 0 "$rc"
  DISK_FREE_OVERRIDE_MB=6143 run --check 2>/dev/null; rc=$?;  check "one MB under the default heavy floor (6144)" 75 "$rc"
  DISK_FREE_OVERRIDE_MB=6144 run --check 2>/dev/null; rc=$?;  check "exactly the default heavy floor" 0 "$rc"
  # arguments reach the command intact, spaces included
  out="$(DISK_FREE_OVERRIDE_MB=20000 run -- sh -c 'printf "%s|" "$@"' _ "a b" "c" 2>/dev/null)"
  [ "$out" = "a b|c|" ] || bad "guard: arguments must reach the command intact (got '$out')"
  # usage errors
  run 2>/dev/null; rc=$?;                                   check "no command and no --check" 64 "$rc"
  run --bogus 2>/dev/null; rc=$?;                           check "unknown option" 64 "$rc"
  run --min-free-mb abc --check 2>/dev/null; rc=$?;         check "non-numeric floor" 64 "$rc"
  run --wait-secs -1 --check 2>/dev/null; rc=$?;            check "non-numeric wait" 64 "$rc"
  # a floor past what [ -lt ] can compare is a usage error (it used to read as "plenty": rc 0 with 100 MB free)
  DISK_FREE_OVERRIDE_MB=100 run --min-free-mb 9223372036854775808 --check 2>/dev/null; rc=$?
  check "a 19-digit floor (past int64) is a usage error, not a go-ahead" 64 "$rc"
  DISK_FREE_OVERRIDE_MB=100 run --min-free-mb 99999999999999999999 --check 2>/dev/null; rc=$?
  check "a 20-digit floor is a usage error" 64 "$rc"
  DISK_FREE_OVERRIDE_MB=99999999999999999999 run --check 2>/dev/null; rc=$?
  check "a 20-digit reading is unreadable: 76, not a go-ahead" 76 "$rc"
  # lib missing -> cannot decide -> refuse (76), never run, and the refusal is in the log the runbook points at
  rm -f "$W/ran"; : > "$HEAVY_GUARD_LOG"
  HEAVY_GUARD_LIB=/nonexistent-lib "$g" -- sh -c 'touch "$1"' _ "$W/ran" 2>/dev/null; rc=$?
  check "missing lib refuses" 76 "$rc"; [ ! -e "$W/ran" ] || bad "missing lib: the command RAN"
  grep -q 'REFUSED lib_unloadable=/nonexistent-lib rc=76' "$HEAVY_GUARD_LOG" || bad "missing lib: refusal not in the log ($(cat "$HEAVY_GUARD_LOG"))"
  # a lib from before disk_state_of existed cannot decide either: refused, not run
  printf 'disk_free_mb() { printf 20000; }\ndisk_headroom_state() { printf ok; }\n' > "$W/lib-old.sh"
  rm -f "$W/ran"; HEAVY_GUARD_LIB="$W/lib-old.sh" "$g" -- sh -c 'touch "$1"' _ "$W/ran" 2>/dev/null; rc=$?
  check "a lib without disk_state_of refuses" 76 "$rc"; [ ! -e "$W/ran" ] || bad "old lib: the command RAN"
  # a log that cannot be written must not change the verdict
  : > "$W/afile"
  DISK_FREE_OVERRIDE_MB=100 HEAVY_GUARD_LOG="$W/afile/sub/log" run --check 2>/dev/null; rc=$?
  check "unwritable log keeps the verdict" 75 "$rc"
  # wait path: a fake df whose answer changes per call (low, then recovered)
  mkdir -p "$W/bin"; echo 0 > "$W/dfn"
  cat > "$W/bin/df" <<EOF
#!/bin/sh
n=\$(cat "$W/dfn"); echo \$((n+1)) > "$W/dfn"
if [ "\$n" -ge "\${FAKE_DF_RECOVER_AT:-1}" ]; then a=9000; else a=2000; fi
echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
echo "/dev/fake 100000 90000 \$a 90% /"
EOF
  chmod +x "$W/bin/df"
  rm -f "$W/ran"; echo 0 > "$W/dfn"
  PATH="$W/bin:$PATH" DISK_HEADROOM_PATH=/ HEAVY_GUARD_POLL_SECS=1 FAKE_DF_RECOVER_AT=1 run --wait-secs 5 -- sh -c 'touch "$1"' _ "$W/ran" 2>/dev/null; rc=$?
  check "waits for the disk to recover, then runs" 0 "$rc"; [ -e "$W/ran" ] || bad "wait: the command did not run after the disk recovered"
  rm -f "$W/ran"; echo 0 > "$W/dfn"
  PATH="$W/bin:$PATH" DISK_HEADROOM_PATH=/ HEAVY_GUARD_POLL_SECS=1 FAKE_DF_RECOVER_AT=999 run --wait-secs 2 -- sh -c 'touch "$1"' _ "$W/ran" 2>/dev/null; rc=$?
  check "a disk that never recovers is refused after the wait" 75 "$rc"; [ ! -e "$W/ran" ] || bad "wait: ran although the disk never recovered"
  # a zero-padded wait ("08" is invalid OCTAL to $(( ))) and an unreadable clock must both END on a low disk, not spin:
  # a fake clock (+4 s per read) and a no-op sleep make the wait instant; `bounded` kills a guard that does not end
  # the number shown in a refusal is the reading the verdict came from (a df whose answer changes per call: 2000 then 9000)
  echo 0 > "$W/dfn"; : > "$HEAVY_GUARD_LOG"
  PATH="$W/bin:$PATH" DISK_HEADROOM_PATH=/ FAKE_DF_RECOVER_AT=1 run --check 2>"$W/err"; rc=$?
  check "refusal on the first reading of a changing df" 75 "$rc"
  grep -q '2000 MB free' "$W/err" && grep -q 'free_mb=2000 ' "$HEAVY_GUARD_LOG" || bad "refusal shows another reading than the one decided on ($(cat "$W/err") | $(cat "$HEAVY_GUARD_LOG"))"
  # a pinned reading / the kill switch let a step through unchecked: stderr and the log say so; a real reading says nothing
  : > "$HEAVY_GUARD_LOG"
  DISK_FREE_OVERRIDE_MB=20000 run --what pinned --check 2>"$W/err"; rc=$?
  check "a pinned reading above the floor goes ahead" 0 "$rc"
  grep -q 'NOTE.*pinned.*bypassed' "$W/err" || bad "bypass: stderr must say the check was bypassed ($(cat "$W/err"))"
  grep -q "BYPASS what='pinned'" "$HEAVY_GUARD_LOG" || bad "bypass: not in the log ($(cat "$HEAVY_GUARD_LOG"))"
  : > "$HEAVY_GUARD_LOG"; echo 0 > "$W/dfn"
  PATH="$W/bin:$PATH" DISK_HEADROOM_PATH=/ FAKE_DF_RECOVER_AT=0 run --what real --check 2>"$W/err"; rc=$?
  check "a real reading above the floor goes ahead" 0 "$rc"
  [ ! -s "$W/err" ] && ! grep -q BYPASS "$HEAVY_GUARD_LOG" || bad "a real reading must not claim a bypass ($(cat "$W/err") | $(cat "$HEAVY_GUARD_LOG"))"
  bounded() { # bounded <secs> <cmd...>: the command's rc, or 124 when it was still running after <secs> (it is killed)
    local p i=0 n=$(( $1 * 10 )); shift; "$@" & p=$!
    while kill -0 "$p" 2>/dev/null && [ "$i" -lt "$n" ]; do sleep 0.1; i=$((i+1)); done
    if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; fi
    wait "$p"
  }
  mkdir -p "$W/bin2"; echo 1000000 > "$W/clk"
  printf '#!/bin/sh\n[ -n "$FAKE_CLOCK_BAD" ] && exit 1\n[ "$1" = "+%%s" ] || exec /bin/date "$@"\nn=$(cat "%s"); echo $((n+4)) > "%s"; echo $n\n' "$W/clk" "$W/clk" > "$W/bin2/date"
  printf '#!/bin/sh\necho "$1" >> "%s"\nexit 0\n' "$W/sleeps" > "$W/bin2/sleep"; chmod +x "$W/bin2/date" "$W/bin2/sleep"
  bounded 5 env PATH="$W/bin2:$PATH" HEAVY_GUARD_LIB="$lib" DISK_FREE_OVERRIDE_MB=100 "$g" --wait-secs 08 --check 2>/dev/null; rc=$?
  check "a zero-padded --wait-secs (08) on a low disk ends with 75" 75 "$rc"
  bounded 5 env PATH="$W/bin2:$PATH" FAKE_CLOCK_BAD=1 HEAVY_GUARD_LIB="$lib" DISK_FREE_OVERRIDE_MB=100 "$g" --wait-secs 5 --check 2>/dev/null; rc=$?
  check "an unreadable clock on a low disk stops waiting: 75" 75 "$rc"
  bounded 5 env HEAVY_GUARD_LIB="$lib" DISK_FREE_OVERRIDE_MB=100 "$g" --wait-secs 1234567890 --check 2>/dev/null; rc=$?
  check "a wait of more than 9 digits is a usage error, not a 39-year wait" 64 "$rc"
  # a poll step past int64 cannot be compared with the remaining wait: it falls back to 15 s, so no sleep is longer than that
  : > "$W/sleeps"
  bounded 5 env PATH="$W/bin2:$PATH" HEAVY_GUARD_POLL_SECS=99999999999999999999 HEAVY_GUARD_LIB="$lib" DISK_FREE_OVERRIDE_MB=100 "$g" --wait-secs 100 --check 2>/dev/null; rc=$?
  check "a huge HEAVY_GUARD_POLL_SECS still ends a wait on a low disk with 75" 75 "$rc"
  [ -s "$W/sleeps" ] && [ "$(sort -n "$W/sleeps" | tail -1)" -le 15 ] || bad "a huge HEAVY_GUARD_POLL_SECS must not lengthen the sleep step (longest: $(sort -n "$W/sleeps" | tail -1))"
}

# ── lookup cases (ga-g9ptej): the guard run from places that have NO packs/ next to it ───────────────────────
# HEAVY_GUARD_LIB is never set here (lg unsets it): the lookup itself is what is under test. Each layout is a
# copy of the guard under test, so a mutant of the guard goes through exactly the same places as the real one.
LK="$W/lk"; LK_REL=packs/town-deltas/assets/scripts
mkdir -p "$LK/city/$LK_REL" "$LK/badcity/$LK_REL" "$LK/emptycity"
cp "$REAL_LIB" "$LK/city/$LK_REL/disk-headroom-lib.sh"
printf 'disk_free_mb() { printf 20000; }\ndisk_headroom_state() { printf ok; }\n' > "$LK/lib-old.sh"   # from before disk_state_of existed
cp "$LK/lib-old.sh" "$LK/badcity/$LK_REL/disk-headroom-lib.sh"
LK_CAN_HIDE=0   # 1 once a chmod 000 file proved unreadable here (as root it stays readable: that case is skipped)
lookup_cases() { # lookup_cases <guard>
  local g="$1" rc L f
  lk_layout() { # lk_layout <dir> <lib-source|->: <dir>/scripts/heavy-guard.sh and, unless "-", the lib at <dir>/packs/...
    mkdir -p "$1/scripts"; cp -f "$g" "$1/scripts/heavy-guard.sh"
    [ "$2" = - ] && return 0
    mkdir -p "$1/$LK_REL"; chmod 644 "$1/$LK_REL/disk-headroom-lib.sh" 2>/dev/null; cp -f "$2" "$1/$LK_REL/disk-headroom-lib.sh"
  }
  lg() { env -u HEAVY_GUARD_LIB -u GC_CITY -u GC_CITY_PATH "$@"; }   # a clean slate: each case sets what it needs
  # (a) the copy the deployment really runs (.gc/scripts/heavy-guard.sh): nothing beside it, the lib only in the city
  lk_layout "$LK/hq/.gc" -; L="$LK/hq/.gc/scripts/heavy-guard.sh"
  lg GC_CITY_PATH="$LK/city" DISK_FREE_OVERRIDE_MB=20000 "$L" --check 2>/dev/null; rc=$?
  check "lookup: the .gc/scripts copy finds the lib through GC_CITY_PATH (ok disk)" 0 "$rc"
  lg GC_CITY_PATH="$LK/city" DISK_FREE_OVERRIDE_MB=3000 "$L" --check 2>/dev/null; rc=$?
  check "lookup: the .gc/scripts copy on a low disk is 75, never 76 with the lib present" 75 "$rc"
  rm -f "$W/ran"
  lg GC_CITY_PATH="$LK/city" DISK_FREE_OVERRIDE_MB=20000 "$L" --what t -- sh -c 'touch "$1"; exit 7' _ "$W/ran" 2>/dev/null; rc=$?
  check "lookup: the .gc/scripts copy runs the command and propagates its rc" 7 "$rc"; [ -e "$W/ran" ] || bad "lookup: the command did not run from the .gc/scripts copy"
  lg GC_CITY="$LK/city" DISK_FREE_OVERRIDE_MB=20000 "$L" --check 2>/dev/null; rc=$?
  check "lookup: GC_CITY is honoured when GC_CITY_PATH is not set" 0 "$rc"
  # (b) the lib exists nowhere on the list: fail CLOSED (76), the command never runs, and the refusal says where it looked
  rm -f "$W/ran"; : > "$HEAVY_GUARD_LOG"
  lg GC_CITY_PATH="$LK/emptycity" DISK_FREE_OVERRIDE_MB=20000 "$L" -- sh -c 'touch "$1"' _ "$W/ran" 2>"$W/err"; rc=$?
  check "lookup: no lib anywhere refuses with 76" 76 "$rc"; [ ! -e "$W/ran" ] || bad "lookup: the command RAN with no lib anywhere"
  grep -q "search order:.*$LK/emptycity/$LK_REL" "$W/err" || bad "lookup: stderr must list the places looked at ($(cat "$W/err"))"
  grep -q "REFUSED lib_unloadable=.* rc=76 search_order=.*$LK/emptycity/$LK_REL" "$HEAVY_GUARD_LOG" || bad "lookup: the refusal log must list the places looked at ($(cat "$HEAVY_GUARD_LOG"))"
  lg DISK_FREE_OVERRIDE_MB=20000 "$L" --check 2>/dev/null; rc=$?
  check "lookup: no GC_CITY_PATH/GC_CITY and nothing beside the script refuses with 76" 76 "$rc"
  # (c) the script reached through a symlink (relative, absolute, a chain): the lib sits next to the REAL script only
  lk_layout "$LK/realhq" "$REAL_LIB"; mkdir -p "$LK/linkrel" "$LK/linkabs" "$LK/linkchain"
  ln -sf ../realhq/scripts/heavy-guard.sh "$LK/linkrel/heavy-guard.sh"
  ln -sf "$LK/realhq/scripts/heavy-guard.sh" "$LK/linkabs/heavy-guard.sh"
  ln -sf ../linkrel/heavy-guard.sh "$LK/linkchain/heavy-guard.sh"
  for L in "$LK/linkrel" "$LK/linkabs" "$LK/linkchain"; do
    lg GC_CITY_PATH="$LK/emptycity" DISK_FREE_OVERRIDE_MB=20000 "$L/heavy-guard.sh" --check 2>/dev/null; rc=$?
    check "lookup: a symlinked script finds the lib next to the real script ($(basename "$L"))" 0 "$rc"
  done
  # (d) precedence: the lib next to the script beats the city's, with or without a city
  lk_layout "$LK/nearfirst" "$REAL_LIB"
  lg GC_CITY_PATH="$LK/badcity" DISK_FREE_OVERRIDE_MB=20000 "$LK/nearfirst/scripts/heavy-guard.sh" --check 2>/dev/null; rc=$?
  check "lookup: the lib next to the script wins over the city's" 0 "$rc"
  lg DISK_FREE_OVERRIDE_MB=20000 "$LK/nearfirst/scripts/heavy-guard.sh" --check 2>/dev/null; rc=$?
  check "lookup: the lib next to the script is enough without any city variable" 0 "$rc"
  # (e) HEAVY_GUARD_LIB is exactly that file: a missing one is 76 even though the city has a good lib
  rm -f "$W/ran"
  lg GC_CITY_PATH="$LK/city" HEAVY_GUARD_LIB=/nonexistent-lib DISK_FREE_OVERRIDE_MB=20000 "$LK/hq/.gc/scripts/heavy-guard.sh" -- sh -c 'touch "$1"' _ "$W/ran" 2>/dev/null; rc=$?
  check "lookup: HEAVY_GUARD_LIB set to a missing file does not fall through to the city's lib" 76 "$rc"; [ ! -e "$W/ran" ] || bad "lookup: the command RAN although HEAVY_GUARD_LIB was missing"
  # (f) readable but unable to decide is NOT 'absent': refused, never skipped for the city's good copy
  rm -f "$W/ran"; lk_layout "$LK/badnear" "$LK/lib-old.sh"
  lg GC_CITY_PATH="$LK/city" DISK_FREE_OVERRIDE_MB=20000 "$LK/badnear/scripts/heavy-guard.sh" -- sh -c 'touch "$1"' _ "$W/ran" 2>/dev/null; rc=$?
  check "lookup: a readable lib that cannot decide is refused (76), not skipped" 76 "$rc"; [ ! -e "$W/ran" ] || bad "lookup: the command RAN on a lib that cannot decide"
  # (g) missing or unreadable IS 'absent': a directory with the lib's name, a chmod 000 file -> the next candidate
  mkdir -p "$LK/dirnear/scripts" "$LK/dirnear/$LK_REL/disk-headroom-lib.sh"; cp -f "$g" "$LK/dirnear/scripts/heavy-guard.sh"
  lg GC_CITY_PATH="$LK/city" DISK_FREE_OVERRIDE_MB=20000 "$LK/dirnear/scripts/heavy-guard.sh" --check 2>/dev/null; rc=$?
  check "lookup: a directory with the lib's name counts as absent, the city's lib is used" 0 "$rc"
  lk_layout "$LK/hidden" "$REAL_LIB"; f="$LK/hidden/$LK_REL/disk-headroom-lib.sh"; chmod 000 "$f" 2>/dev/null
  if [ -r "$f" ]; then LK_CAN_HIDE=0; else
    LK_CAN_HIDE=1
    lg GC_CITY_PATH="$LK/city" DISK_FREE_OVERRIDE_MB=20000 "$LK/hidden/scripts/heavy-guard.sh" --check 2>/dev/null; rc=$?
    check "lookup: an unreadable lib counts as absent, the city's lib is used" 0 "$rc"
  fi
}

mk_mutant() { # mk_mutant <src> <dst> <sed-expr>  — fails the selftest if the expression changed nothing
  # sed > file leaves mode 644, and the guard mutants are EXECUTED: without +x every one of them died with rc 126 (permission
  # denied) whatever it changed, so no mutant proved anything
  sed "$3" "$1" > "$2"; chmod +x "$2"; cmp -s "$1" "$2" && { bad "mutant '$3' did not change $(basename "$1")"; return 1; }; return 0
}

before=$FAIL; lib_cases "$REAL_LIB";                      [ "$FAIL" -eq "$before" ] || echo "(lib cases failed on the real lib)"
before=$FAIL; guard_cases "$REAL_GUARD" "$REAL_LIB";      [ "$FAIL" -eq "$before" ] || echo "(guard cases failed on the real files)"
before=$FAIL; lookup_cases "$REAL_GUARD";                 [ "$FAIL" -eq "$before" ] || echo "(lookup cases failed on the real guard)"

# mutants: each must make at least one case fail
survive() { # survive <name> -- the FAIL counter must have grown since $before
  if [ "$FAIL" -gt "$before" ]; then FAIL=$before; PASS=$((PASS+1)); else bad "mutant '$1' survived: no case noticed it"; fi
}
M="$W/mut"; mkdir -p "$M"
mk_mutant "$REAL_LIB" "$M/lib-le.sh" 's/-lt "\$_dh_min"/-le "$_dh_min"/' && { before=$FAIL; lib_cases "$M/lib-le.sh" >/dev/null; survive "lib: -lt became -le"; }
mk_mutant "$REAL_LIB" "$M/lib-gt.sh" 's/-lt "\$_dh_min"/-gt "$_dh_min"/' && { before=$FAIL; lib_cases "$M/lib-gt.sh" >/dev/null; survive "lib: comparison inverted"; }
mk_mutant "$REAL_LIB" "$M/lib-unk.sh" "s/\*\[!0-9\]\*) return 1 ;; esac\$/*[!0-9]*) printf 0; return 0 ;; esac/" && { before=$FAIL; lib_cases "$M/lib-unk.sh" >/dev/null; survive "lib: unreadable collapses to 0 MB"; }
mk_mutant "$REAL_LIB" "$M/lib-ok.sh" "s/''|\*\[!0-9\]\*) printf 'unknown'; return 0 ;; esac/''|*[!0-9]*) printf 'ok'; return 0 ;; esac/" && { before=$FAIL; lib_cases "$M/lib-ok.sh" >/dev/null; survive "lib: unknown collapses to ok"; }
mk_mutant "$REAL_LIB" "$M/lib-else.sh" "s/\*) printf 'unknown' ;; esac/*) printf 'ok' ;; esac/" && { before=$FAIL; lib_cases "$M/lib-else.sh" >/dev/null; survive "lib: a comparison that could not be made reads as ok"; }
mk_mutant "$REAL_LIB" "$M/lib-capr.sh" '/^ *\[ "\${#_dh_[ov]}" -le 9 \] || return 1$/d' && { before=$FAIL; lib_cases "$M/lib-capr.sh" >/dev/null; survive "lib: no magnitude cap on the reading"; }
mk_mutant "$REAL_LIB" "$M/lib-cape.sh" '/^\[ "\${#DISK_[A-Z_]*}" -le 9 \]/d' && { before=$FAIL; lib_cases "$M/lib-cape.sh" >/dev/null; survive "lib: no magnitude cap on the env floors"; }
mk_mutant "$REAL_GUARD" "$M/g-run.sh" 's/exit 75/exec "$@"/' && { before=$FAIL; guard_cases "$M/g-run.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: low runs the command anyway"; }
mk_mutant "$REAL_GUARD" "$M/g-local.sh" 's/exit 75/exit 97/' && { before=$FAIL; guard_cases "$M/g-local.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: refusal uses the run-local rc 97"; }
mk_mutant "$REAL_GUARD" "$M/g-open.sh" 's/^    exit 76$/    exec "$@"/' && { before=$FAIL; guard_cases "$M/g-open.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: unknown disk runs the command (fail open)"; }
mk_mutant "$REAL_GUARD" "$M/g-nowait.sh" 's/\[ "\$now" -ge "\$deadline" \]/true/' && { before=$FAIL; guard_cases "$M/g-nowait.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: never waits"; }
mk_mutant "$REAL_GUARD" "$M/g-octal.sh" 's/^wait_s=\$(( 10#\$wait_s ))$/:/' && { before=$FAIL; guard_cases "$M/g-octal.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: --wait-secs 08 read as octal"; }
mk_mutant "$REAL_GUARD" "$M/g-noclock.sh" '/^  case "\$now" in/d' && { before=$FAIL; guard_cases "$M/g-noclock.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: an unreadable clock keeps the wait loop going"; }

mk_mutant "$REAL_GUARD" "$M/g-cappoll.sh" '/^\[ "\${#HG_POLL}" -le 9 \]/d' && { before=$FAIL; guard_cases "$M/g-cappoll.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: no magnitude cap on the poll step"; }
mk_mutant "$REAL_GUARD" "$M/g-capmin.sh" '/^\[ "\${#min}" -le 9 \]/d' && { before=$FAIL; guard_cases "$M/g-capmin.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: no magnitude cap on --min-free-mb"; }
mk_mutant "$REAL_GUARD" "$M/g-nolog.sh" '/hg_log "REFUSED lib_unloadable/d' && { before=$FAIL; guard_cases "$M/g-nolog.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: the lib-unloadable refusal leaves no log line"; }
mk_mutant "$REAL_GUARD" "$M/g-reread.sh" 's/^\[ -n "\$free" \] || free="?"$/free="$(disk_free_mb 2>\/dev\/null)" || free="?"/' && { before=$FAIL; guard_cases "$M/g-reread.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: the refusal shows a second reading"; }
mk_mutant "$REAL_GUARD" "$M/g-nonote.sh" '/goes ahead with the disk check bypassed/d' && { before=$FAIL; guard_cases "$M/g-nonote.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: a bypass is silent on stderr"; }
mk_mutant "$REAL_GUARD" "$M/g-nobylog.sh" '/hg_log "BYPASS/d' && { before=$FAIL; guard_cases "$M/g-nobylog.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: a bypass leaves no log line"; }

# lookup mutants (ga-g9ptej): each one removes or bends one rule of the lib lookup
lkm() { # lkm <file> <name> <sed-expr>
  mk_mutant "$REAL_GUARD" "$M/$1.sh" "$3" && { before=$FAIL; lookup_cases "$M/$1.sh" >/dev/null 2>&1; survive "$2"; }
}
lkm l-nocity  "lookup: the city candidate is gone"                    's#HG_CANDS+=("\$HG_CITY_ROOT/\$HG_LIB_REL")#:#'
lkm l-noreal  "lookup: the symlink-resolved candidate is gone"        's#HG_CANDS+=("\$HG_REAL/\.\./\$HG_LIB_REL")#:#'
lkm l-nofollow "lookup: symlinks are not followed"                    's#while \[ -L "\$p" \]; do#while false; do#'
lkm l-relink  "lookup: a relative link target is read against the cwd" 's#\*) p="\$(dirname "\$p")/\$t" ;;#*) p="$t" ;;#'
lkm l-nocityvar "lookup: GC_CITY is ignored"                          's#\${GC_CITY_PATH:-\${GC_CITY:-}}#${GC_CITY_PATH:-}#'
lkm l-nonear  "lookup: the candidate next to the script is gone"      's#^HG_CANDS=("\$HG_HERE/\.\./\$HG_LIB_REL")$#HG_CANDS=()#'
lkm l-override "lookup: HEAVY_GUARD_LIB falls through to the search"  's#^if \[ -z "\$HG_LIB" \]; then$#if true; then#'
lkm l-skipbad "lookup: a lib that cannot decide is skipped"           's#\[ -f "\$hg_c" \] && \[ -r "\$hg_c" \]#[ -f "$hg_c" ] \&\& [ -r "$hg_c" ] \&\& grep -q disk_state_of "$hg_c"#'
lkm l-nofile  "lookup: a directory is taken for the lib"              's#\[ -f "\$hg_c" \] && ##'
lkm l-nomsg   "lookup: the refusal does not list the places looked"   's#\${HG_LOOKED:+ (search order: \$HG_LOOKED)}##'
lkm l-nolog   "lookup: the refusal log does not list the places"      's#\${HG_LOOKED:+ search_order=\$HG_LOOKED}##'
[ "$LK_CAN_HIDE" = 1 ] && lkm l-noread "lookup: an unreadable lib is taken for the lib" 's# && \[ -r "\$hg_c" \]##'

echo "heavy-guard selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
