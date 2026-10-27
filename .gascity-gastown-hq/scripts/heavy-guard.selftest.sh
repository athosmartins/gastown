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
unset HEAVY_GUARD_SELFTEST_MAX_DROP_MB HEAVY_GUARD_SELFTEST_MAX_FILE_MB WBASE WLOOP_BAD
unset DISK_GO_MIN_MB DISK_PUSH_MIN_MB DISK_PUSH_STOP_MB HEAVY_GUARD_WATCH_SECS HEAVY_GUARD_KILL_GRACE_SECS HEAVY_GUARD_PUSH_LOCK_DIR HEAVY_GUARD_PUSH_LOCK_WAIT_SECS HEAVY_GUARD_PUSH_LOCK_POLL_SECS HEAVY_GUARD_PUSH_LOCK_MAXAGE_SECS

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
  # the Go floor (ga-edkfip): 13312 by default, and the same rule as the other two floors for a bad value in the env
  gf() { env "$@" sh -c '. "$1"; echo "$DISK_GO_MIN_MB"' _ "$lib"; }
  [ "$(gf X=1)" = 13312 ]                                              || bad "lib: the default Go floor must be 13312 (got '$(gf X=1)')"
  [ "$(gf DISK_GO_MIN_MB=20480)" = 20480 ]                             || bad "lib: DISK_GO_MIN_MB=20480 must be honoured (got '$(gf DISK_GO_MIN_MB=20480)')"
  [ "$(gf DISK_GO_MIN_MB=garbage)" = 13312 ]                           || bad "lib: a Go floor that is not a number must fall back to 13312 (got '$(gf DISK_GO_MIN_MB=garbage)')"
  [ "$(gf DISK_GO_MIN_MB=)" = 13312 ]                                  || bad "lib: an empty Go floor must fall back to 13312 (got '$(gf DISK_GO_MIN_MB=)')"
  [ "$(gf DISK_GO_MIN_MB=99999999999999999999)" = 13312 ]              || bad "lib: a Go floor past int64 must fall back to 13312 (got '$(gf DISK_GO_MIN_MB=99999999999999999999)')"
  [ "$(gf DISK_GO_MIN_MB=1234567890)" = 13312 ]                        || bad "lib: a Go floor of more than 9 digits must fall back to 13312 (got '$(gf DISK_GO_MIN_MB=1234567890)')"
  [ "$(gf DISK_GO_MIN_MB=123456789)" = 123456789 ]                     || bad "lib: a 9-digit Go floor is still a floor (got '$(gf DISK_GO_MIN_MB=123456789)')"
  # the PUSH floors (ga-pwd2h6): a `git push` may START at 5000 MB and is STOPPED below 4000 MB; same rule as the other floors for a bad value
  pf() { env "$@" sh -c '. "$1"; echo "$DISK_PUSH_MIN_MB/$DISK_PUSH_STOP_MB"' _ "$lib"; }
  [ "$(pf X=1)" = 5000/4000 ]                                          || bad "lib: the default push floors must be 5000 (start) / 4000 (stop) (got '$(pf X=1)')"
  [ "$(pf DISK_PUSH_MIN_MB=4500 DISK_PUSH_STOP_MB=3500)" = 4500/3500 ] || bad "lib: DISK_PUSH_MIN_MB / DISK_PUSH_STOP_MB must be honoured (got '$(pf DISK_PUSH_MIN_MB=4500 DISK_PUSH_STOP_MB=3500)')"
  [ "$(pf DISK_PUSH_MIN_MB=garbage)" = 5000/4000 ]                     || bad "lib: a push start floor that is not a number must fall back to 5000 (got '$(pf DISK_PUSH_MIN_MB=garbage)')"
  [ "$(pf DISK_PUSH_STOP_MB=)" = 5000/4000 ]                           || bad "lib: an empty push stop floor must fall back to 4000 (got '$(pf DISK_PUSH_STOP_MB=)')"
  [ "$(pf DISK_PUSH_STOP_MB=garbage)" = 5000/4000 ]                    || bad "lib: a push stop floor that is not a number must fall back to 4000, not be clamped to the start floor (got '$(pf DISK_PUSH_STOP_MB=garbage)')"
  [ "$(pf DISK_PUSH_MIN_MB=1234567890)" = 5000/4000 ]                  || bad "lib: a push start floor of more than 9 digits must fall back to 5000 (got '$(pf DISK_PUSH_MIN_MB=1234567890)')"
  [ "$(pf DISK_PUSH_STOP_MB=99999999999999999999)" = 5000/4000 ]       || bad "lib: a push stop floor past int64 must fall back to 4000 (got '$(pf DISK_PUSH_STOP_MB=99999999999999999999)')"
  # a stop floor ABOVE the start floor would kill a push the moment it starts: it is pulled down to the start floor
  [ "$(pf DISK_PUSH_MIN_MB=3500)" = 3500/3500 ]                        || bad "lib: a stop floor above the start floor must be pulled down to it (got '$(pf DISK_PUSH_MIN_MB=3500)')"
  [ "$(pf DISK_PUSH_STOP_MB=6000)" = 5000/5000 ]                       || bad "lib: DISK_PUSH_STOP_MB=6000 must be pulled down to the start floor 5000 (got '$(pf DISK_PUSH_STOP_MB=6000)')"
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

# ── Go class cases (ga-edkfip): go_cases <guard> <lib> ───────────────────────────────────────────────────────
# A Go build/test needs 13 GB, not 6: 19/10 a cold build of cmd/gc started just over the heavy floor and left 2 GB. The
# readings used here sit BETWEEN the two floors (9000: ok for a heavy step, low for a Go step). A fake `go` on PATH marks
# whether the command RAN, so "refused" is proved by the command not running, not only by the rc.
go_cases() {
  local g="$1" lib="$2" rc out
  mkdir -p "$W/gobin"; printf '#!/bin/sh\ntouch "%s/goran"\necho "go $*"\nexit 9\n' "$W" > "$W/gobin/go"; chmod +x "$W/gobin/go"
  run() { PATH="$W/gobin:$PATH" HEAVY_GUARD_LIB="$lib" "$g" "$@"; }
  # refused: the label alone (--check has no command), every command shape, and the command does not run
  : > "$HEAVY_GUARD_LOG"
  DISK_FREE_OVERRIDE_MB=9000 run --check --what go-test 2>"$W/err"; rc=$?
  check "go: --what go-test between the floors is refused with 75" 75 "$rc"
  grep -q 'mbp-run.sh --exec --go' "$W/err" || bad "go: the refusal must point at 'mbp-run.sh --exec --go' ($(cat "$W/err"))"
  grep -q 'docs/runbooks/mbp-offload.md' "$W/err" || bad "go: the refusal must name the runbook"
  grep -q '13312 MB floor' "$W/err" || bad "go: the refusal must show the Go floor, 13312 ($(cat "$W/err"))"
  grep -q 'rc 75' "$W/err" || bad "go: the refusal must say rc 75"
  grep -q '97 is also a usage error' "$W/err" && grep -q '98 also a --push path that does not exist' "$W/err" || bad "go: the refusal must say that mbp-run 97 and 98 are not always 'MacBook unavailable' ($(cat "$W/err"))"
  grep -q "REFUSED what='go-test' free_mb=9000 min_mb=13312 class=go rc=75" "$HEAVY_GUARD_LOG" || bad "go: refusal not in the log with class=go ($(cat "$HEAVY_GUARD_LOG"))"
  local lbl
  for lbl in go-build go-vet go-install "go build ./cmd/gc" "Go-Test" "go test internal/mail" "go_test"; do
    DISK_FREE_OVERRIDE_MB=9000 run --check --what "$lbl" 2>/dev/null; rc=$?
    check "go: the label '$lbl' is a Go step (75 between the floors)" 75 "$rc"
  done
  local cmdline
  while IFS= read -r cmdline; do
    rm -f "$W/goran"
    # shellcheck disable=SC2086
    DISK_FREE_OVERRIDE_MB=9000 run --what step -- $cmdline 2>/dev/null; rc=$?
    check "go: the command '$cmdline' is a Go step (75 between the floors)" 75 "$rc"; [ ! -e "$W/goran" ] || bad "go: '$cmdline' RAN on a disk below the Go floor"
  done <<'EOF'
go test ./...
go build ./cmd/gc
go vet ./internal/mail/...
go install ./cmd/gc
env CGO_ENABLED=1 go test ./...
/opt/homebrew/bin/go build ./...
EOF
  # inside a quoted script (sh -c), after ;, &&, |, ( and a backtick
  for cmdline in 'cd /tmp && go test ./...' 'cd /tmp; go vet ./...' 'true | go build ./...' '(go install ./...)' 'echo `go build ./...`' "echo 'go test ./...'" 'FOO=1
go test ./...'; do
    rm -f "$W/goran"
    DISK_FREE_OVERRIDE_MB=9000 run --what step -- sh -c "$cmdline" 2>/dev/null; rc=$?
    check "go: sh -c '$(printf %s "$cmdline" | tr '\n' ' ')' is a Go step (75 between the floors)" 75 "$rc"; [ ! -e "$W/goran" ] || bad "go: sh -c '$cmdline' RAN on a disk below the Go floor"
  done
  # NOT Go steps: the heavy floor (6144) applies, so 9000 goes ahead and the command runs
  for lbl in other go-testdata gopher-build "go" "ego-test" "cargo-test" "heavy step"; do
    DISK_FREE_OVERRIDE_MB=9000 run --check --what "$lbl" 2>/dev/null; rc=$?
    check "go: the label '$lbl' is NOT a Go step (6144 floor, 9000 passes)" 0 "$rc"
  done
  for cmdline in 'go version' 'go env GOPATH' 'echo cargo test mongo build' 'echo gotest' 'echo go-build' 'echo go tests' 'echo ego test'; do
    rm -f "$W/goran"
    DISK_FREE_OVERRIDE_MB=9000 run --what step -- sh -c "$cmdline" >/dev/null 2>&1; rc=$?
    check "go: sh -c '$cmdline' is NOT a Go step (9000 passes the heavy floor)" "$( case "$cmdline" in "go version"|"go env GOPATH") echo 9 ;; *) echo 0 ;; esac )" "$rc"
  done
  # `tr` cannot run (a fake one that fails): the matcher no longer uses it, so NOTHING may change — in particular the shapes glued to
  # punctuation, which an earlier version (tr to split on ; & | ( ) ` " ') read as "not Go" when tr failed: "cd /tmp;go test" ran
  # with 9000 MB free < 13312 (gate run ga-7dd84s). Each one must be refused AND must not run.
  mkdir -p "$W/trbin"; printf '#!/bin/sh\nexit 1\n' > "$W/trbin/tr"; chmod +x "$W/trbin/tr"
  PATH="$W/trbin:$PATH" DISK_FREE_OVERRIDE_MB=9000 run --check --what go-test 2>/dev/null; rc=$?;     check "go: with tr failing, a go-test label is still a Go step" 75 "$rc"
  PATH="$W/trbin:$PATH" DISK_FREE_OVERRIDE_MB=9000 run --check --what Go-Test 2>/dev/null; rc=$?;     check "go: with tr failing, the label Go-Test (capitals) is still a Go step" 75 "$rc"
  for cmdline in 'go test ./...' 'cd /tmp;go test ./...' '(go install ./...)' 'true|go vet ./...' 'cd /tmp && go build ./...' 'echo `go build ./...`' "echo 'go test ./...'"; do
    rm -f "$W/goran"
    PATH="$W/trbin:$PATH" DISK_FREE_OVERRIDE_MB=9000 run --what step -- sh -c "$cmdline" 2>/dev/null; rc=$?
    check "go: with tr failing, sh -c '$cmdline' is still a Go step (75)" 75 "$rc"; [ ! -e "$W/goran" ] || bad "go: with tr failing, sh -c '$cmdline' RAN below the Go floor"
  done
  rm -f "$W/goran"
  PATH="$W/trbin:$PATH" DISK_FREE_OVERRIDE_MB=9000 run --check --what other 2>/dev/null; rc=$?;       check "go: with tr failing, a non-Go step keeps the heavy floor (9000 passes)" 0 "$rc"
  # the floor itself: exactly 13312 goes ahead, one MB under is refused, plenty runs the command and passes its rc through
  DISK_FREE_OVERRIDE_MB=13312 run --check --what go-test 2>/dev/null; rc=$?;   check "go: exactly the Go floor (13312) goes ahead" 0 "$rc"
  DISK_FREE_OVERRIDE_MB=13311 run --check --what go-test 2>/dev/null; rc=$?;   check "go: one MB under the Go floor is refused" 75 "$rc"
  rm -f "$W/goran"
  DISK_FREE_OVERRIDE_MB=20000 run --what go-test -- go test ./... >/dev/null 2>&1; rc=$?
  check "go: with plenty of disk the command runs and its rc comes through" 9 "$rc"; [ -e "$W/goran" ] || bad "go: the Go command did not run with plenty of disk"
  # the class floor is a minimum: --min-free-mb can raise it for one call and never lower it
  DISK_FREE_OVERRIDE_MB=9000 run --check --what go-test --min-free-mb 2000 2>"$W/err"; rc=$?
  check "go: --min-free-mb 2000 cannot lower the Go floor" 75 "$rc"; grep -q '13312 MB floor' "$W/err" || bad "go: a lowered --min-free-mb must still show the 13312 floor ($(cat "$W/err"))"
  DISK_FREE_OVERRIDE_MB=14000 run --check --what go-test --min-free-mb 15000 2>"$W/err"; rc=$?
  check "go: --min-free-mb 15000 raises the Go floor" 75 "$rc"; grep -q '15000 MB floor' "$W/err" || bad "go: a raised --min-free-mb must show the 15000 floor ($(cat "$W/err"))"
  DISK_FREE_OVERRIDE_MB=14000 run --check --what go-test --min-free-mb 13000 2>/dev/null; rc=$?
  check "go: a --min-free-mb under the Go floor leaves 14000 above the Go floor: goes ahead" 0 "$rc"
  # the env knob moves the Go floor, and nothing else
  DISK_FREE_OVERRIDE_MB=9000 DISK_GO_MIN_MB=8000 run --check --what go-test 2>/dev/null; rc=$?;  check "go: DISK_GO_MIN_MB=8000 lets 9000 through for a Go step" 0 "$rc"
  DISK_FREE_OVERRIDE_MB=9000 DISK_GO_MIN_MB=garbage run --check --what go-test 2>/dev/null; rc=$?;  check "go: a garbage DISK_GO_MIN_MB falls back to 13312 (refused)" 75 "$rc"
  # a Go floor BELOW the heavy floor never makes a Go step easier than a heavy one: the larger of the two wins
  DISK_FREE_OVERRIDE_MB=5000 DISK_GO_MIN_MB=1000 run --check --what go-test 2>/dev/null; rc=$?;  check "go: the larger of the Go and heavy floors applies (5000 < 6144)" 75 "$rc"
  # no reading of the disk: a Go step is refused with 76 as any heavy step, and does not run
  rm -f "$W/goran"
  DISK_FREE_OVERRIDE_MB=x run --what step -- go test ./... 2>"$W/err"; rc=$?
  check "go: an unreadable disk refuses a Go step with 76" 76 "$rc"; [ ! -e "$W/goran" ] || bad "go: ran with an unreadable disk"
  # a lib that cannot give the Go floor (older than this guard) refuses a Go step with 76 and SAYS why; a non-Go step is unaffected
  grep -v 'DISK_GO_MIN_MB' "$lib" > "$W/lib-nogo.sh"
  rm -f "$W/goran"
  HEAVY_GUARD_LIB="$W/lib-nogo.sh" DISK_FREE_OVERRIDE_MB=99999 "$g" --what step -- go test ./... 2>"$W/err"; rc=$?
  check "go: a lib without DISK_GO_MIN_MB refuses a Go step with 76" 76 "$rc"; [ ! -e "$W/goran" ] || bad "go: ran on a lib without the Go floor"
  grep -q 'DISK_GO_MIN_MB' "$W/err" || bad "go: the 76 for a lib without the Go floor must name DISK_GO_MIN_MB ($(cat "$W/err"))"
  HEAVY_GUARD_LIB="$W/lib-nogo.sh" DISK_FREE_OVERRIDE_MB=99999 "$g" --check --what other 2>/dev/null; rc=$?
  check "go: a lib without DISK_GO_MIN_MB still serves a non-Go step" 0 "$rc"
  # a non-Go refusal is the old one, byte for byte where it counts: no MacBook recipe, no class tag in the log
  : > "$HEAVY_GUARD_LOG"
  DISK_FREE_OVERRIDE_MB=3000 run --check --what other 2>"$W/err"; rc=$?
  check "go: a non-Go step at 3000 is refused as before" 75 "$rc"
  ! grep -q 'mbp-run.sh --exec --go' "$W/err" || bad "go: a non-Go refusal must not send the step to the MacBook Go recipe"
  grep -q "REFUSED what='other' free_mb=3000 min_mb=6144 rc=75" "$HEAVY_GUARD_LOG" || bad "go: a non-Go refusal keeps its old log line ($(cat "$HEAVY_GUARD_LOG"))"
}

# ── PUSH class cases (ga-pwd2h6): push_cases <guard> <lib> ───────────────────────────────────────────────────
# A `git push` (and the pre-push hook behind it) writes ~0-200 MB, so it gets a floor of its own: starts at 5000 MB (the heavy
# floor is 6144), and a watch STOPS it if the disk falls under 4000 MB while it runs; one push at a time (lock). A fake `git` on
# PATH marks whether the command RAN, so "refused" is proved by the command not running, not only by the rc; a fake `df`
# whose answer the fake git can change makes the disk fall DURING the push. The real git is never called.
push_cases() {
  local g="$1" lib="$2" rc out i lbl cmdline hp dp r1 r2 gp seq RW rr rn rp rq rbad
  local PB="$W/pbin" PD="$W/pdf" LK="$W/plock"
  export HEAVY_GUARD_PUSH_LOCK_DIR="$LK"
  mkdir -p "$PB" "$PD"
  cat > "$PB/git" <<EOF
#!/bin/sh
# the TERM dispositions come FIRST: writing dfnow below is what lets the watch see the disk fall and send the TERM, so a trap installed after that line loses the race on a loaded
# node (the fake dies of the default TERM, rc 143, and the guard answers 78 to a push that was meant to ignore TERM or to exit 0 on it)
[ -n "\$FAKE_GIT_IGNORE_TERM" ] && trap '' TERM
[ -n "\$FAKE_GIT_TERM0" ] && trap 'echo "end \$\$" >> "$W/gitlog"; exit 0' TERM
echo "start \$\$" >> "$W/gitlog"
echo "git \$*" > "$W/gitargs"
[ -n "\$FAKE_GIT_LOCKDIR" ] && [ -d "\$FAKE_GIT_LOCKDIR" ] && echo held >> "$W/lockseen"
[ -n "\$FAKE_GIT_DF" ] && echo "\$FAKE_GIT_DF" > "$W/dfnow"
[ -n "\$FAKE_GIT_DFBAD" ] && : > "$W/dfbad"
[ -n "\$FAKE_GIT_GRANDCHILD" ] && ( "$PB/hook" >/dev/null 2>&1 & echo \$! > "$W/grandchild" )   # duplo-fork (ga-2d14tow): no grupo do push, mas reparentado, fora da cadeia de pais; só o TERM de grupo o alcança
if [ -n "\$FAKE_GIT_TERM0" ]; then
  [ -n "\$FAKE_GIT_SLEEP" ] && { sleep "\$FAKE_GIT_SLEEP" & wait \$!; }
elif [ -n "\$FAKE_GIT_SLEEP" ]; then
  sleep "\$FAKE_GIT_SLEEP"
fi
echo "end \$\$" >> "$W/gitlog"
exit \${FAKE_GIT_RC:-0}
EOF
  # the push's hook: a child in the push's process group that cleans up when it gets TERM (the proof the TERM reached the group)
  cat > "$PB/hook" <<EOF
#!/bin/sh
trap 'echo termed > "$W/hooktermed"; exit 0' TERM
while :; do sleep 1; done
EOF
  cat > "$PD/df" <<EOF
#!/bin/sh
if [ -e "$W/dfbad" ]; then echo "df: no usable answer"; exit 0; fi
echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
echo "/dev/fake 100000 90000 \$(cat "$W/dfnow") 90% /"
EOF
  chmod +x "$PB/git" "$PB/hook" "$PD/df"
  # prun: the reading is pinned by the caller (DISK_FREE_OVERRIDE_MB); wenv: the live fake df, polled every second by the watch
  prun() { PATH="$PB:$PATH" HEAVY_GUARD_LIB="$lib" "$g" "$@"; }
  local -a wenv
  wenv=(PATH="$PD:$PB:$PATH" DISK_HEADROOM_PATH=/ HEAVY_GUARD_LIB="$lib" HEAVY_GUARD_WATCH_SECS=1 HEAVY_GUARD_KILL_GRACE_SECS=3)
  pbounded() { # pbounded <secs> <cmd...>: the command's rc, or 124 when it was still running after <secs> (it is killed)
    local p n=$(( $1 * 10 )) k=0; shift; "$@" & p=$!
    while kill -0 "$p" 2>/dev/null && [ "$k" -lt "$n" ]; do sleep 0.1; k=$((k+1)); done
    if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; fi
    wait "$p"
  }
  p_reset() {
    rm -f "$W/gitlog" "$W/gitargs" "$W/dfbad" "$W/grandchild" "$W/hooktermed" "$W/lockseen" "$W/err" "$LK/owner"; rmdir "$LK" 2>/dev/null
    echo 9000 > "$W/dfnow"; : > "$HEAVY_GUARD_LOG"
  }

  # sections: PUSH_SECTIONS="floor busy" runs only those (default: all); the mutants below name the sections that can notice them
  want() { case " ${PUSH_SECTIONS:-all} " in *" all "*|*" $1 "*) return 0 ;; esac; return 1; }
  if want floor; then
  # (a) the floor: a push starts at 5000 MB; every other heavy step still needs 6144
  p_reset
  DISK_FREE_OVERRIDE_MB=5500 prun --what pre-push -- git push origin HEAD >/dev/null 2>&1; rc=$?
  check "push: git push at 5500 MB (between the push floor and the heavy floor) goes ahead" 0 "$rc"
  [ "$(cat "$W/gitargs" 2>/dev/null)" = "git push origin HEAD" ] || bad "push: the push did not run with its own arguments (got '$(cat "$W/gitargs" 2>/dev/null)')"
  p_reset; rm -f "$W/ran"
  DISK_FREE_OVERRIDE_MB=5500 prun --what t -- sh -c 'touch "$1"' _ "$W/ran" >/dev/null 2>&1; rc=$?
  check "push: another heavy step at 5500 MB is still refused (75)" 75 "$rc"; [ ! -e "$W/ran" ] || bad "push: a non-push heavy step RAN at 5500 MB"
  p_reset
  DISK_FREE_OVERRIDE_MB=4999 prun --what pre-push -- git push origin HEAD 2>"$W/err" >/dev/null; rc=$?
  check "push: one MB under the push floor (4999) is refused with 75" 75 "$rc"
  [ ! -e "$W/gitlog" ] || bad "push: git push RAN below the push floor"
  grep -q '4999 MB free < 5000 MB floor for a git push' "$W/err" || bad "push: the refusal must show the push floor ($(cat "$W/err"))"
  grep -q -e '--no-verify' "$W/err" || bad "push: the refusal must tell the worker not to use --no-verify ($(cat "$W/err"))"
  grep -q 'rc 75' "$W/err" || bad "push: the refusal must say rc 75"
  grep -q "REFUSED what='pre-push' free_mb=4999 min_mb=5000 class=push rc=75" "$HEAVY_GUARD_LOG" || bad "push: refusal not in the log with class=push ($(cat "$HEAVY_GUARD_LOG"))"
  p_reset
  DISK_FREE_OVERRIDE_MB=5000 prun --what pre-push -- git push origin HEAD >/dev/null 2>&1; rc=$?
  check "push: exactly the push floor (5000) goes ahead" 0 "$rc"
  p_reset
  DISK_FREE_OVERRIDE_MB=x prun --what pre-push -- git push origin HEAD >/dev/null 2>&1; rc=$?
  check "push: an unreadable disk refuses a push with 76" 76 "$rc"; [ ! -e "$W/gitlog" ] || bad "push: git push RAN with no reading of the disk"
  # a non-push refusal is the old one: no push wording
  p_reset
  DISK_FREE_OVERRIDE_MB=5500 prun --what t -- sh -c 'true' 2>"$W/err"; rc=$?
  ! grep -q 'git push' "$W/err" || bad "push: a non-push refusal must not talk about git push ($(cat "$W/err"))"

  fi
  if want detect; then
  # (b) what is a push: the command (git, then its own options, then `push`), or a push label when there is no command to look at
  while IFS= read -r cmdline; do
    p_reset
    # shellcheck disable=SC2086
    DISK_FREE_OVERRIDE_MB=5500 prun --what step -- $cmdline >/dev/null 2>&1; rc=$?
    check "push: the command '$cmdline' is a git push (5500 passes)" 0 "$rc"
  done <<'EOF'
git push
git push origin HEAD
git push --force-with-lease origin HEAD
git -C /tmp/some/dir push origin HEAD
git -c core.hooksPath=/dev/null push origin HEAD
git --no-pager push origin HEAD
EOF
  p_reset
  DISK_FREE_OVERRIDE_MB=5500 prun --what step -- "$PB/git" push origin HEAD >/dev/null 2>&1; rc=$?
  check "push: a git given by path ($PB/git push) is a git push" 0 "$rc"
  # NOT pushes: the heavy floor applies (5500 is refused) and the command does not run
  while IFS= read -r cmdline; do
    p_reset
    # shellcheck disable=SC2086
    DISK_FREE_OVERRIDE_MB=5500 prun --what step -- $cmdline >/dev/null 2>&1; rc=$?
    check "push: the command '$cmdline' is NOT a git push (5500 is refused)" 75 "$rc"; [ ! -e "$W/gitlog" ] || bad "push: '$cmdline' RAN at 5500 MB"
  done <<'EOF'
git status
git pull
git push-foo
git -C push status
git commit -m push
git fetch push
git -x push
echo push
EOF
  for cmdline in 'git push origin HEAD' 'cd /tmp && git push' 'echo git push'; do
    p_reset
    DISK_FREE_OVERRIDE_MB=5500 prun --what step -- sh -c "$cmdline" >/dev/null 2>&1; rc=$?
    check "push: sh -c '$cmdline' is not seen as a git push (the heavy floor applies, 5500 is refused)" 75 "$rc"; [ ! -e "$W/gitlog" ] || bad "push: sh -c '$cmdline' RAN at 5500 MB"
  done
  # a label alone (--check has no command)
  for lbl in push git-push pre-push Push "git push" pre_push "git-push origin"; do
    DISK_FREE_OVERRIDE_MB=5500 prun --check --what "$lbl" 2>/dev/null; rc=$?
    check "push: the label '$lbl' is a push (5500 passes)" 0 "$rc"
    DISK_FREE_OVERRIDE_MB=4999 prun --check --what "$lbl" 2>/dev/null; rc=$?
    check "push: the label '$lbl' under the push floor (4999) is refused" 75 "$rc"
  done
  for lbl in pushover unpush wa-push cargo-push "heavy step" go; do
    DISK_FREE_OVERRIDE_MB=5500 prun --check --what "$lbl" 2>/dev/null; rc=$?
    check "push: the label '$lbl' is NOT a push (the heavy floor refuses 5500)" 75 "$rc"
  done
  # a label cannot make another command a push: with a command to look at, only the command counts
  p_reset; rm -f "$W/ran"
  DISK_FREE_OVERRIDE_MB=5500 prun --what push -- sh -c 'touch "$1"' _ "$W/ran" >/dev/null 2>&1; rc=$?
  check "push: --what push on a command that is not a git push keeps the heavy floor (5500 refused)" 75 "$rc"; [ ! -e "$W/ran" ] || bad "push: a push label let a non-push command run at 5500 MB"
  # a Go step stays a Go step: the higher floor wins over the push class
  p_reset
  DISK_FREE_OVERRIDE_MB=9000 prun --what go-test -- git push >/dev/null 2>&1; rc=$?
  check "push: --what go-test on a git push keeps the Go floor (9000 refused)" 75 "$rc"; [ ! -e "$W/gitlog" ] || bad "push: a Go-labelled step RAN under the Go floor"

  fi
  if want minfree; then
  # (c) --min-free-mb can RAISE the push floor, never lower it (the stop floor is the Dolt CRITICAL margin)
  p_reset
  DISK_FREE_OVERRIDE_MB=4500 prun --min-free-mb 3000 --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push: --min-free-mb 3000 cannot lower the push floor (4500 refused)" 75 "$rc"; [ ! -e "$W/gitlog" ] || bad "push: a lowered --min-free-mb let a push run under 5000"
  DISK_FREE_OVERRIDE_MB=5500 prun --min-free-mb 6144 --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push: --min-free-mb 6144 raises the push floor (5500 refused)" 75 "$rc"
  DISK_FREE_OVERRIDE_MB=5000 prun --min-free-mb 5000 --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push: the workers' own --min-free-mb 5000 keeps working (5000 goes ahead)" 0 "$rc"
  # the env knob moves the push floor, and only that
  p_reset
  DISK_FREE_OVERRIDE_MB=4600 DISK_PUSH_MIN_MB=4500 prun --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push: DISK_PUSH_MIN_MB=4500 lets 4600 through" 0 "$rc"
  DISK_FREE_OVERRIDE_MB=4400 DISK_PUSH_MIN_MB=4500 prun --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push: DISK_PUSH_MIN_MB=4500 refuses 4400" 75 "$rc"
  DISK_FREE_OVERRIDE_MB=4600 DISK_PUSH_MIN_MB=garbage prun --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push: a garbage DISK_PUSH_MIN_MB falls back to 5000 (4600 refused)" 75 "$rc"
  fi
  if want nopushlib; then
  # a lib from before the push class cannot give the push floors: the step keeps the heavy floor (the old behaviour), it is not blocked
  grep -v 'DISK_PUSH_' "$lib" > "$W/lib-nopush.sh"
  p_reset
  HEAVY_GUARD_LIB="$W/lib-nopush.sh" DISK_FREE_OVERRIDE_MB=5500 PATH="$PB:$PATH" "$g" --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push: a lib without the push floors keeps the heavy floor (5500 refused)" 75 "$rc"; [ ! -e "$W/gitlog" ] || bad "push: a push RAN on a lib without the push floors under the heavy floor"
  HEAVY_GUARD_LIB="$W/lib-nopush.sh" DISK_FREE_OVERRIDE_MB=20000 PATH="$PB:$PATH" "$g" --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push: a lib without the push floors still lets a push through when the disk is plentiful" 0 "$rc"; [ -e "$W/gitlog" ] || bad "push: the push did not run on a lib without the push floors"

  fi
  if want stop; then
  # (d) the watch: under the stop floor while the push runs → TERM to its whole process group, rc 78, nothing left alive
  p_reset
  pbounded 20 env "${wenv[@]}" FAKE_GIT_DF=3900 FAKE_GIT_SLEEP=8 FAKE_GIT_GRANDCHILD=1 "$g" --what pre-push -- git push origin HEAD 2>"$W/err" >/dev/null; rc=$?
  check "push watch: a disk that falls to 3900 MB (< 4000) during the push interrupts it with rc 78" 78 "$rc"
  ! grep -q '^end' "$W/gitlog" 2>/dev/null || bad "push watch: the push ran to the end although the disk fell under the stop floor"
  grep -q 'INTERRUPTED' "$W/err" && grep -q 'rc 78' "$W/err" || bad "push watch: stderr must say INTERRUPTED and rc 78 ($(cat "$W/err"))"
  grep -q '3[0-9][0-9][0-9] MB free < 4000 MB stop floor' "$W/err" || bad "push watch: the message must show the reading and the 4000 stop floor ($(cat "$W/err"))"
  grep -q 'Do NOT repeat it' "$W/err" && grep -q 'Tell the Mayor' "$W/err" || bad "push watch: the message must say not to repeat it and to tell the Mayor ($(cat "$W/err"))"
  grep -q "INTERRUPTED what='pre-push'.*stop_mb=4000.*rc=78" "$HEAVY_GUARD_LOG" || bad "push watch: the interruption is not in the log ($(cat "$HEAVY_GUARD_LOG"))"
  gp="$(cat "$W/grandchild" 2>/dev/null)"
  if [ -n "$gp" ] && kill -0 "$gp" 2>/dev/null; then bad "push watch: a child of the push (pid $gp) is still alive: the TERM did not go to the whole process group"; kill "$gp" 2>/dev/null; fi
  [ -e "$W/hooktermed" ] || bad "push watch: the push's hook never saw the TERM (the whole group must be told first, the KILL comes only after the grace)"
  [ ! -e "$LK" ] || bad "push watch: the lock was not released after an interruption"
  fi
  if want ignoreterm; then
  # a push that ignores TERM is KILLed after the grace (3 s here), and the guard still answers 78 well before the push would have ended by itself
  p_reset; i=$(date +%s)
  pbounded 25 env "${wenv[@]}" FAKE_GIT_DF=3900 FAKE_GIT_SLEEP=15 FAKE_GIT_IGNORE_TERM=1 "$g" --what pre-push -- git push origin HEAD 2>/dev/null >/dev/null; rc=$?
  check "push watch: a push that ignores TERM is KILLed after the grace and the guard answers 78" 78 "$rc"
  ! grep -q '^end' "$W/gitlog" 2>/dev/null || bad "push watch: a push that ignores TERM ran to its end"
  [ $(( $(date +%s) - i )) -lt 13 ] || bad "push watch: the KILL after the grace came too late ($(( $(date +%s) - i )) s)"
  fi
  if want term0; then
  # a push that exits 0 even when told to stop did finish: its 0 comes through, it is not turned into a 78. One run, no second chance: the race that
  # used to turn this 0 into a 78 now and then (ga-dousipw) is gone from the guard, and the section `race` right below is the proof for that
  p_reset
  pbounded 25 env "${wenv[@]}" FAKE_GIT_DF=3900 FAKE_GIT_SLEEP=8 FAKE_GIT_TERM0=1 "$g" --what pre-push -- git push origin HEAD 2>/dev/null >/dev/null; rc=$?
  check "push watch: a push that ended with 0 keeps its 0 even after the watch told it to stop" 0 "$rc"
  fi
  if want race; then
  # ga-dousipw: the guard's own `wait` must never be cut short. When the watch signalled the guard, bash answered -1 instead of the push's status
  # (measured on bash 3.2.57 and on 5.2.21: from 1 run in 40 alone to 1 in 3 with 24 guards at once) and a push that ended with 0 came back as 78.
  # One run cannot show a race, so: the term0 push above, 24 guards at once, each with its own df reading, lock and log, 4 rounds; every one answers 0.
  # Those rates are from the guard BEFORE ga-2d14tow. Its pgrep walk in hg_stop_group now puts a few ms between the USR1 and the TERM, and on a quiet node the
  # same stress came back 0 of 120 wrong even on the guard that still had the USR1 (27/10, bash 5.2.21): this run is a stress, the USR1 check below is the proof
  RW="$W/race"; mkdir -p "$RW/bin"
  cat > "$RW/bin/git" <<'EOF'
#!/bin/sh
echo 3900 > "$RACE_W/dfnow"
trap 'exit 0' TERM
sleep 8 & wait $!
exit 0
EOF
  cat > "$RW/bin/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
echo "/dev/fake 100000 90000 $(cat "$RACE_W/dfnow") 90% /"
EOF
  chmod +x "$RW/bin/git" "$RW/bin/df"
  rp=""
  for rr in 1 2 3 4; do
    rn=1
    while [ "$rn" -le 24 ]; do
      mkdir -p "$RW/$rr.$rn"; echo 9000 > "$RW/$rr.$rn/dfnow"
      ( pbounded 40 env RACE_W="$RW/$rr.$rn" PATH="$RW/bin:$PATH" DISK_HEADROOM_PATH=/ HEAVY_GUARD_LIB="$lib" HEAVY_GUARD_WATCH_SECS=1 HEAVY_GUARD_KILL_GRACE_SECS=3 \
          HEAVY_GUARD_PUSH_LOCK_DIR="$RW/$rr.$rn/lock" HEAVY_GUARD_LOG="$RW/$rr.$rn/log" "$g" --what pre-push -- git push origin HEAD >/dev/null 2>&1
        echo $? > "$RW/$rr.$rn/rc" ) &
      rp="$rp $!"; rn=$((rn+1))
    done
    for rq in $rp; do wait "$rq"; done; rp=""
  done
  # vazio/falhou/ilegível (a world with no rc file: the run never finished) → counted as a bad run, never as a 0
  rbad=0
  for rr in 1 2 3 4; do rn=1; while [ "$rn" -le 24 ]; do [ "$(cat "$RW/$rr.$rn/rc" 2>/dev/null)" = 0 ] || rbad=$((rbad+1)); rn=$((rn+1)); done; done
  if [ "$rbad" -eq 0 ]; then ok; else bad "push watch: $rbad of 96 pushes that ended with 0 (24 guards at once) did not come back 0"; fi
  # the cause, not only the symptom (the run above is a race: a quiet machine can pass it): nothing may trap or send USR1 to the guard again
  if grep -Eq 'trap .* USR1|kill -USR1' "$g"; then bad "push watch: the guard traps or sends USR1 again: a trapped signal cuts its wait short (ga-dousipw)"; else ok; fi
  fi
  if want stopfloor; then
  # exactly the stop floor is NOT under it; a dip that stays above it does not interrupt
  for i in 4000 4100; do
    p_reset
    pbounded 20 env "${wenv[@]}" FAKE_GIT_DF=$i FAKE_GIT_SLEEP=3 "$g" --what pre-push -- git push origin HEAD 2>"$W/err" >/dev/null; rc=$?
    check "push watch: a disk that falls to $i MB (not under 4000) does not interrupt the push" 0 "$rc"
    grep -q '^end' "$W/gitlog" 2>/dev/null || bad "push watch: the push was stopped at $i MB"
    [ ! -s "$W/err" ] || bad "push watch: a push that was not stopped must leave stderr empty (got '$(cat "$W/err")')"
  done
  p_reset
  pbounded 20 env "${wenv[@]}" FAKE_GIT_DF=3999 FAKE_GIT_SLEEP=8 "$g" --what pre-push -- git push origin HEAD 2>/dev/null >/dev/null; rc=$?
  check "push watch: one MB under the stop floor (3999) interrupts" 78 "$rc"
  fi
  if want blind; then
  # a reading the watch cannot take is not a reason to kill a push: it keeps running, and the log says the watch was blind
  p_reset
  pbounded 20 env "${wenv[@]}" FAKE_GIT_DFBAD=1 FAKE_GIT_SLEEP=3 "$g" --what pre-push -- git push origin HEAD 2>"$W/err" >/dev/null; rc=$?
  check "push watch: a df that stops answering during the push does not kill it" 0 "$rc"
  grep -q '^end' "$W/gitlog" 2>/dev/null || bad "push watch: the push was stopped because df stopped answering"
  grep -q 'WATCH_UNREADABLE' "$HEAVY_GUARD_LOG" || bad "push watch: an unreadable reading during the watch must leave a log line ($(cat "$HEAVY_GUARD_LOG"))"
  fi
  if want rc; then
  # the command's own rc comes through, and the lock is let go
  for i in 1 128; do
    p_reset
    pbounded 20 env "${wenv[@]}" FAKE_GIT_RC=$i "$g" --what pre-push -- git push origin HEAD >/dev/null 2>&1; rc=$?
    check "push watch: the push's own rc ($i) comes through" "$i" "$rc"
    [ ! -e "$LK" ] || bad "push watch: the lock was not released after a push that exited $i"
  done
  # arguments reach the push intact
  p_reset
  pbounded 20 env "${wenv[@]}" "$g" --what pre-push -- git push "origin" "a b" >/dev/null 2>&1
  [ "$(cat "$W/gitargs" 2>/dev/null)" = "git push origin a b" ] || bad "push watch: arguments did not reach the push ($(cat "$W/gitargs" 2>/dev/null))"
  fi
  if want nonpush; then
  # not a push: no watch and no lock, the command is exec'd as before
  p_reset
  DISK_FREE_OVERRIDE_MB=20000 prun --what t -- sh -c '[ -d "$1" ] && exit 5; exit 0' _ "$LK" >/dev/null 2>&1; rc=$?
  check "push: a heavy step that is not a push takes no lock" 0 "$rc"

  fi
  if want posint; then
  # hg_posint reads every push tunable: loaded from the guard under test and called directly (a $(...) per call keeps each case apart)
  pi() { ( eval "$(sed -n '/^hg_posint() {/,/^}/p' "$g")"; hg_posint X "$1" "$2" "$3" 2>/dev/null; printf '%s' "${X-<unset>}" ); }
  [ "$(pi 08 3 0)" = 8 ]               || bad "posint: '08' is the decimal 8, not an octal error (got '$(pi 08 3 0)')"
  [ "$(pi 09 3 0)" = 9 ]               || bad "posint: '09' is the decimal 9 (got '$(pi 09 3 0)')"
  [ "$(pi 0 3 0)" = 3 ]                || bad "posint: a 0 where 0 is not allowed falls back to the default (got '$(pi 0 3 0)')"
  [ "$(pi 0 900 1)" = 0 ]              || bad "posint: a 0 where 0 is allowed stays 0 (got '$(pi 0 900 1)')"
  [ "$(pi abc 3 0)" = 3 ]              || bad "posint: text falls back to the default (got '$(pi abc 3 0)')"
  [ "$(pi -5 3 0)" = 3 ]               || bad "posint: a negative number falls back to the default (got '$(pi -5 3 0)')"
  [ "$(pi '' 3 0)" = 3 ]               || bad "posint: empty falls back to the default (got '$(pi '' 3 0)')"
  [ "$(pi 1234567890 3 0)" = 3 ]       || bad "posint: more than 9 digits falls back to the default (got '$(pi 1234567890 3 0)')"
  [ "$(pi 123456789 3 0)" = 123456789 ] || bad "posint: 9 digits is still a number (got '$(pi 123456789 3 0)')"
  fi
  if want serial; then
  # (e) the lock: one pre-push at a time
  p_reset
  pbounded 30 env "${wenv[@]}" FAKE_GIT_SLEEP=2 HEAVY_GUARD_PUSH_LOCK_POLL_SECS=1 "$g" --what pre-push -- git push a >/dev/null 2>&1 &
  r1=$!; sleep 0.7
  pbounded 30 env "${wenv[@]}" FAKE_GIT_SLEEP=2 HEAVY_GUARD_PUSH_LOCK_POLL_SECS=1 "$g" --what pre-push -- git push b >/dev/null 2>&1 &
  r2=$!
  wait "$r1"; rc=$?; check "push lock: the first push finishes with 0" 0 "$rc"
  wait "$r2"; rc=$?; check "push lock: the second push waits for the lock and then finishes with 0" 0 "$rc"
  seq="$(awk '{printf "%s ", $1}' "$W/gitlog" 2>/dev/null)"
  [ "$seq" = "start end start end " ] || bad "push lock: two pushes at once must run one after the other (events: $seq)"
  [ ! -e "$LK" ] || bad "push lock: the lock was left behind"
  # the lock really is held while the push runs, in the default place too (GC_CITY_PATH/.gc/heavy-guard-push.lock)
  p_reset
  pbounded 20 env "${wenv[@]}" FAKE_GIT_LOCKDIR="$LK" "$g" --what pre-push -- git push >/dev/null 2>&1
  [ -e "$W/lockseen" ] || bad "push lock: the lock was not held while the push ran"
  p_reset
  pbounded 20 env -u HEAVY_GUARD_PUSH_LOCK_DIR "${wenv[@]}" FAKE_GIT_LOCKDIR="$GC_CITY_PATH/.gc/heavy-guard-push.lock" "$g" --what pre-push -- git push >/dev/null 2>&1
  [ -e "$W/lockseen" ] || bad "push lock: the default lock is not \$GC_CITY_PATH/.gc/heavy-guard-push.lock"
  fi
  if want busy; then
  # a live holder that never lets go: the waiter gives up after its wait with rc 79 (not 75: the disk is fine), names the holder, and does not run
  p_reset; sleep 60 & hp=$!
  mkdir "$LK"; echo "$hp $(date +%s)" > "$LK/owner"
  pbounded 20 env "${wenv[@]}" HEAVY_GUARD_PUSH_LOCK_WAIT_SECS=2 HEAVY_GUARD_PUSH_LOCK_POLL_SECS=1 "$g" --what pre-push -- git push 2>"$W/err" >/dev/null; rc=$?
  check "push lock: a lock held by a live push for the whole wait is refused with 79" 79 "$rc"; [ ! -e "$W/gitlog" ] || bad "push lock: the push RAN without the lock"
  grep -q "pid $hp" "$W/err" && grep -q 'rc 79' "$W/err" || bad "push lock: the refusal must name the holder's pid and say rc 79 ($(cat "$W/err"))"
  grep -q "REFUSED what='pre-push' push_lock_busy.*rc=79" "$HEAVY_GUARD_LOG" || bad "push lock: refusal not in the log ($(cat "$HEAVY_GUARD_LOG"))"
  [ -d "$LK" ] || bad "push lock: a waiter that gave up must not remove the lock it never held"
  # a wait of 0 is "do not wait", and a zero-padded number is a decimal ("09" is invalid OCTAL to $(( )))
  p_reset; mkdir "$LK"; echo "$hp $(date +%s)" > "$LK/owner"
  i=$(date +%s)
  pbounded 20 env "${wenv[@]}" HEAVY_GUARD_PUSH_LOCK_WAIT_SECS=0 "$g" --what pre-push -- git push 2>/dev/null >/dev/null; rc=$?
  check "push lock: HEAVY_GUARD_PUSH_LOCK_WAIT_SECS=0 refuses a busy lock at once (79)" 79 "$rc"
  [ $(( $(date +%s) - i )) -lt 3 ] || bad "push lock: a wait of 0 waited"
  pbounded 20 env "${wenv[@]}" HEAVY_GUARD_PUSH_LOCK_WAIT_SECS=2 HEAVY_GUARD_PUSH_LOCK_POLL_SECS=09 "$g" --what pre-push -- git push 2>/dev/null >/dev/null; rc=$?
  check "push lock: a zero-padded poll (09) is a decimal, not an octal error" 79 "$rc"
  # --check takes no lock: a decision, nothing runs
  DISK_FREE_OVERRIDE_MB=5500 prun --check --what push 2>/dev/null; rc=$?
  check "push lock: --check does not need the lock" 0 "$rc"
  kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
  fi
  if want age; then
  # a lock whose holder is older than the max age is stale even if its pid is alive (pid reuse / a hung push): taken over
  p_reset; sleep 60 & hp=$!
  mkdir "$LK"; echo "$hp $(( $(date +%s) - 100000 ))" > "$LK/owner"
  pbounded 20 env "${wenv[@]}" HEAVY_GUARD_PUSH_LOCK_WAIT_SECS=2 HEAVY_GUARD_PUSH_LOCK_POLL_SECS=1 "$g" --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push lock: a lock older than the max age is taken over" 0 "$rc"
  kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
  fi
  if want dead; then
  # a dead holder: taken over
  p_reset; true & dp=$!; wait "$dp"
  mkdir "$LK"; echo "$dp $(date +%s)" > "$LK/owner"
  pbounded 20 env "${wenv[@]}" HEAVY_GUARD_PUSH_LOCK_WAIT_SECS=2 HEAVY_GUARD_PUSH_LOCK_POLL_SECS=1 "$g" --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push lock: a lock whose holder is dead is taken over" 0 "$rc"; [ -e "$W/gitlog" ] || bad "push lock: the push did not run after taking over a dead holder's lock"
  fi
  if want garbage; then
  # an owner file nobody can read as "<pid> <epoch>" is a lock that cannot be judged: respected, never taken
  p_reset; mkdir "$LK"; echo "garbage" > "$LK/owner"
  pbounded 20 env "${wenv[@]}" HEAVY_GUARD_PUSH_LOCK_WAIT_SECS=2 HEAVY_GUARD_PUSH_LOCK_POLL_SECS=1 "$g" --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push lock: an owner file that cannot be judged is respected (79)" 79 "$rc"; [ ! -e "$W/gitlog" ] || bad "push lock: the push RAN over a lock whose owner could not be judged"
  [ -d "$LK" ] || bad "push lock: a lock that could not be judged was removed"
  # an owner file that EXISTS but cannot be read (chmod 000; as root it stays readable and the case is skipped): the same, respected
  p_reset; sleep 60 & hp=$!
  mkdir "$LK"; echo "$hp $(date +%s)" > "$LK/owner"; chmod 000 "$LK/owner" 2>/dev/null
  if [ ! -r "$LK/owner" ]; then
    pbounded 20 env "${wenv[@]}" HEAVY_GUARD_PUSH_LOCK_WAIT_SECS=2 HEAVY_GUARD_PUSH_LOCK_POLL_SECS=1 "$g" --what pre-push -- git push >/dev/null 2>"$W/err"; rc=$?
    check "push lock: an owner file that cannot be READ is respected (79)" 79 "$rc"; [ ! -e "$W/gitlog" ] || bad "push lock: the push RAN over a lock whose owner file was unreadable"
    [ -d "$LK" ] || bad "push lock: a lock whose owner file was unreadable was removed"
  fi
  chmod 600 "$LK/owner" 2>/dev/null; kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
  fi
  if want fresh; then
  # no owner file: a FRESH directory is somebody still writing it (wait), an OLD one is a crash between mkdir and the owner (taken over)
  p_reset; mkdir "$LK"
  pbounded 20 env "${wenv[@]}" HEAVY_GUARD_PUSH_LOCK_WAIT_SECS=2 HEAVY_GUARD_PUSH_LOCK_POLL_SECS=1 "$g" --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push lock: a fresh lock directory without an owner is respected (79)" 79 "$rc"; [ ! -e "$W/gitlog" ] || bad "push lock: the push RAN over a fresh ownerless lock"
  touch -t 202001010000 "$LK"
  pbounded 20 env "${wenv[@]}" HEAVY_GUARD_PUSH_LOCK_WAIT_SECS=2 HEAVY_GUARD_PUSH_LOCK_POLL_SECS=1 "$g" --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push lock: an old lock directory without an owner is taken over" 0 "$rc"
  fi
  if want nocreate; then
  # a lock that cannot be created at all: refused 76 (fail closed), never run unlocked
  p_reset; : > "$W/pfile"
  pbounded 20 env PATH="$PB:$PATH" HEAVY_GUARD_LIB="$lib" HEAVY_GUARD_PUSH_LOCK_DIR="$W/pfile/sub" HEAVY_GUARD_PUSH_LOCK_WAIT_SECS=2 HEAVY_GUARD_PUSH_LOCK_POLL_SECS=1 DISK_FREE_OVERRIDE_MB=9000 "$g" --what pre-push -- git push >/dev/null 2>"$W/err"; rc=$?
  check "push lock: a lock that cannot be created refuses with 76" 76 "$rc"; [ ! -e "$W/gitlog" ] || bad "push lock: the push RAN with no lock"
  fi
  if want diskrelease; then
  # a refusal for the disk lets the lock go
  p_reset
  DISK_FREE_OVERRIDE_MB=4000 prun --what pre-push -- git push >/dev/null 2>&1; rc=$?
  check "push lock: a push refused for the disk is 75" 75 "$rc"; [ ! -e "$LK" ] || bad "push lock: the lock was left behind by a refused push"
  fi
  if want sigterm; then
  # the guard itself told to stop (the session is killed): it takes the push group down with it and lets the lock go
  p_reset
  env "${wenv[@]}" FAKE_GIT_SLEEP=30 "$g" --what pre-push -- git push >/dev/null 2>&1 &
  gp=$!
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$W/gitlog" ] && break; sleep 0.25; done
  kill -TERM "$gp" 2>/dev/null; wait "$gp" 2>/dev/null; rc=$?
  check "push lock: a guard that is told to stop exits 143" 143 "$rc"
  [ ! -e "$LK" ] || bad "push lock: a guard that was told to stop left the lock behind"
  hp="$(awk '$1=="start"{print $2}' "$W/gitlog" 2>/dev/null | head -1)"
  sleep 0.3
  if [ -n "$hp" ] && kill -0 "$hp" 2>/dev/null; then bad "push lock: the push (pid $hp) outlived the guard that was told to stop"; kill "$hp" 2>/dev/null; fi
  fi
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

# ── ambient write limit (ga-e6ug8gq) ───────────────────────────────────────────────────────────────────────
# Run through the guard itself (`heavy-guard.sh --what X -- bash scripts/heavy-guard.selftest.sh`, the sanctioned route) this selftest starts under a 512 MB `ulimit -f`, soft and hard. Then "the guard capped the step at
# 512 MB" and "the guard did not cap it" print the SAME number in the child (524288), so the cases that tell them apart go green by accident and the guard mutants that drop the default cap survive. Those assertions are
# SKIPPED, visibly (AMBIENTE note and exit 97 at the end), instead of passing or failing by luck. They need a baseline that a 512 MB cap would change: the soft AND the hard limit each unlimited or above 524288 KB.
# vazio/falhou/ilegível (the reading prints nothing, or something that is neither "unlimited" nor a number) → cannot tell the cap from the baseline: AMB_OK=0, the skipping side; unlimited → ok; a number: ok above 524288 only
amb_ok() { case "$1" in unlimited) return 0 ;; ''|*[!0-9]*) return 1 ;; *) [ "$1" -gt 524288 ] ;; esac; }
AMB_OK=0; amb_ok "$(bash -c 'ulimit -S -f' 2>/dev/null)" && amb_ok "$(bash -c 'ulimit -H -f' 2>/dev/null)" && AMB_OK=1

# ── file-cap cases (ga-e6ug8gq): fcap_cases <guard> <lib> ─────────────────────────────────────────────────
# 27/10 05:09-05:24: an ad-hoc mutant battery on a selftest ran an awk mutant that looped for ever and wrote 4.2 and 5.6 GB into $TMPDIR; the disk hit 0 twice and Dolt took ENOSPC. The writer below IS that loop, stopped at 8M lines
# (~260 MB) only so that a guard WITHOUT the cap does not fill the disk of this selftest. `bash -c 'ulimit -f'` everywhere: sh is POSIX mode on macOS (512-byte units) and dash on Linux.
fcap_cases() {
  local g="$1" lib="$2" rc out base t0 sz ev FB="$W/fbin"
  mkdir -p "$FB"
  run() { DISK_FREE_OVERRIDE_MB=20000 HEAVY_GUARD_LIB="$lib" "$g" "$@"; }
  base="$(bash -c 'ulimit -f')"
  cat > "$W/fcap-loop.sh" << 'EOF'
#!/bin/bash
awk -v f="$1" 'BEGIN { while (1) { print "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" > f; if (++i > 8000000) exit } }'
echo "awk_rc=$?" > "$2"
EOF
  cp "$W/fcap-loop.sh" "$W/fcap-loop.selftest.sh"
  printf '#!/bin/bash\nbash -c "ulimit -f" > "%s/git-ulimit"\n' "$W" > "$FB/git"; chmod +x "$FB/git"
  floop() { # floop <desc> <script> <guard invocation up to and including -->: the loop under the guard must die from the cap, at the cap, fast
    local desc="$1" script="$2"; shift 2
    rm -f "$W/big" "$W/ev"; t0=$SECONDS
    "$@" bash "$W/$script" "$W/big" "$W/ev" 2>/dev/null; rc=$?
    check "fcap: $desc: the guard returns the command's own rc (the script outlives the writer it lost)" 0 "$rc"
    sz="$(wc -c < "$W/big" 2>/dev/null | tr -d ' ')"
    [ "$sz" = 4194304 ] || bad "fcap: $desc: the write loop must stop at exactly the 4 MB cap, 4194304 bytes (got '${sz:-no file}')"
    [ "$((SECONDS - t0))" -lt 5 ] || bad "fcap: $desc: the write loop must die in under 5 s (took $((SECONDS - t0)))"
    ev="$(cat "$W/ev" 2>/dev/null)"
    case "$ev" in awk_rc=[1-9]*) ;; *) bad "fcap: $desc: the writer must be KILLED by the cap (153 = SIGXFSZ, or an EFBIG exit), not end by itself (got '$ev')" ;; esac
  }
  floop "--max-file-mb 4 on a plain step" fcap-loop.sh run --max-file-mb 4 --what t --
  floop "a selftest step takes the class cap (HEAVY_GUARD_SELFTEST_MAX_FILE_MB=4)" fcap-loop.selftest.sh env HEAVY_GUARD_SELFTEST_MAX_FILE_MB=4 DISK_FREE_OVERRIDE_MB=20000 HEAVY_GUARD_LIB="$lib" "$g" --what t --
  # the cap as the child sees it, in KB (bash's unit): the caller's number beats the class default and the env seam sets it. These three read the same under the 512 MB ambient limit (8, 3 and 7 MB are under it), so they run either way
  out="$(run --max-file-mb 8 --what repack -- bash -c 'ulimit -f')";             [ "$out" = 8192 ] || bad "fcap: --max-file-mb 8 caps any step at 8192 KB (got '$out')"
  out="$(run --max-file-mb 3 --what selftest -- bash -c 'ulimit -f')";           [ "$out" = 3072 ] || bad "fcap: the caller's number beats the class default (got '$out')"
  out="$(HEAVY_GUARD_SELFTEST_MAX_FILE_MB=7 run --what selftest -- bash -c 'ulimit -f')"; [ "$out" = 7168 ] || bad "fcap: HEAVY_GUARD_SELFTEST_MAX_FILE_MB sets the class cap (got '$out')"
  # 512 MB for the selftest/mutant class and nothing for the rest: the child reads 524288 when capped and its baseline when not, which differ only if the ambient limit is not itself 512 MB or less (AMB_OK)
  if [ "$AMB_OK" = 1 ]; then
    out="$(run --what selftest-hq -- bash -c 'ulimit -f')";                         [ "$out" = 524288 ] || bad "fcap: a selftest LABEL gets the default 512 MB cap, 524288 KB (got '$out')"
    out="$(run --what 'Mutant battery' -- bash -c 'ulimit -f')";                    [ "$out" = 524288 ] || bad "fcap: a mutant label (capitals ignored) gets the default cap (got '$out')"
    out="$(run --what t -- bash -c 'ulimit -f' x foo.selftest.sh)";                [ "$out" = 524288 ] || bad "fcap: a *.selftest.sh word in the command gets the default cap (got '$out')"
    out="$(run --what t -- bash -c 'ulimit -f' x run-mutants.sh)";                 [ "$out" = 524288 ] || bad "fcap: a *mutant* word in the command gets the default cap (got '$out')"
    out="$(run --what t -- bash -c 'ulimit -f' x hq-mutate.py)";                   [ "$out" = 524288 ] || bad "fcap: hq-mutate.py gets the default cap (got '$out')"
    out="$(run --what repack -- bash -c 'ulimit -f')";                              [ "$out" = "$base" ] || bad "fcap: an ordinary heavy step is NOT capped by default, a repack can write a big pack (got '$out', was '$base')"
    out="$(run --max-file-mb 0 --what selftest -- bash -c 'ulimit -f')";           [ "$out" = "$base" ] || bad "fcap: --max-file-mb 0 is the explicit way to run a selftest uncapped (got '$out')"
    out="$(HEAVY_GUARD_SELFTEST_MAX_FILE_MB=0 run --what selftest -- bash -c 'ulimit -f')"; [ "$out" = 524288 ] || bad "fcap: a class cap of 0 in the env falls back to 512 MB, it does not uncap (got '$out')"
    out="$(HEAVY_GUARD_SELFTEST_MAX_FILE_MB=abc run --what selftest -- bash -c 'ulimit -f')"; [ "$out" = 524288 ] || bad "fcap: a class cap that is not a number falls back to 512 MB (got '$out')"
  fi
  # a Go step and a push keep their own rules (a Go build and a git pack write big files): a word `selftest` in their command does not cap them
  out="$(run --what go-test -- bash -c 'ulimit -f' x selftest)";                  [ "$AMB_OK" != 1 ] || [ "$out" = "$base" ] || bad "fcap: a Go step is not capped by the selftest class (got '$out')"
  rm -f "$W/git-ulimit"
  PATH="$FB:$PATH" HEAVY_GUARD_PUSH_LOCK_DIR="$W/fplock" run --what t -- git push origin fix/x-selftest >/dev/null 2>&1; rc=$?
  check "fcap: the push runs" 0 "$rc"
  [ "$AMB_OK" != 1 ] || [ "$(cat "$W/git-ulimit" 2>/dev/null)" = "$base" ] || bad "fcap: a push is not capped by the selftest class (got '$(cat "$W/git-ulimit" 2>/dev/null)')"
  rm -f "$W/git-ulimit"
  PATH="$FB:$PATH" run --what t -- git repack -a selftest-pack >/dev/null 2>&1; rc=$?
  check "fcap: the repack runs" 0 "$rc"
  [ "$AMB_OK" != 1 ] || [ "$(cat "$W/git-ulimit" 2>/dev/null)" = "$base" ] || bad "fcap: a git command is never in the selftest class, a repack writes a big pack on purpose (got '$(cat "$W/git-ulimit" 2>/dev/null)')"
  # --check runs nothing, so there is nothing to cap, and a cap given with it is not an error
  run --check --max-file-mb 4 --what selftest 2>/dev/null; rc=$?;               check "fcap: --check accepts --max-file-mb" 0 "$rc"
  # usage: whole number of MB, at most 9 digits, a value is needed
  run --max-file-mb abc --what t -- true 2>/dev/null; rc=$?;                    check "fcap: --max-file-mb abc is a usage error" 64 "$rc"
  run --max-file-mb -1 --what t -- true 2>/dev/null; rc=$?;                     check "fcap: --max-file-mb -1 is a usage error" 64 "$rc"
  run --max-file-mb 1234567890 --what t -- true 2>/dev/null; rc=$?;            check "fcap: --max-file-mb of 10 digits is a usage error" 64 "$rc"
  run --what t --max-file-mb 2>/dev/null; rc=$?;                                check "fcap: --max-file-mb without a value is a usage error" 64 "$rc"
  # fail CLOSED: a cap that cannot be set (and whose reading is not already at or under the ask: a tighter HARD limit that ulimit will not let go) means the step does not run. The ulimit builtin is replaced through BASH_ENV (read by the guard's own bash)
  fk() { # fk <name> <ulimit function body> — the guard with that fake ulimit, the step is `touch ran`
    printf 'ulimit() { %s; }\n' "$2" > "$W/ulimit-$1.env"; rm -f "$W/fran"
    BASH_ENV="$W/ulimit-$1.env" run --max-file-mb 512 --what t -- touch "$W/fran" 2>"$W/ferr"; rc=$?
  }
  : > "$HEAVY_GUARD_LOG"   # the log is shared by every run of this selftest: the refusal below has to be a line written by THIS run
  fk none 'return 1'
  check "fcap: a ulimit that fails and reads nothing refuses with 76" 76 "$rc"; [ ! -e "$W/fran" ] || bad "fcap: the step RAN with no cap set (ulimit failing, nothing readable)"
  grep -q 'REFUSED' "$W/ferr" && grep -q 'rc 76' "$W/ferr" || bad "fcap: the refusal must say REFUSED and rc 76 ($(cat "$W/ferr"))"
  grep -q "REFUSED what='t' fsize_cap" "$HEAVY_GUARD_LOG" || bad "fcap: the refusal must be in the log ($(tail -n 2 "$HEAVY_GUARD_LOG"))"
  # the reading itself succeeds in the next three: only its VALUE can make the guard refuse
  fk unl '[ $# -eq 1 ] && { echo unlimited; return 0; }; return 1'
  check "fcap: a ulimit that cannot set and reads unlimited refuses with 76" 76 "$rc"; [ ! -e "$W/fran" ] || bad "fcap: the step RAN with the cap unlimited"
  fk empty '[ $# -eq 1 ] && return 0; return 1'
  check "fcap: a ulimit that cannot set and reads nothing (rc 0) refuses with 76" 76 "$rc"; [ ! -e "$W/fran" ] || bad "fcap: the step RAN with an empty reading of the cap"
  fk big '[ $# -eq 1 ] && echo 999999999; return 0'
  check "fcap: a ulimit that says it set the cap but reads a looser one refuses with 76" 76 "$rc"; [ ! -e "$W/fran" ] || bad "fcap: the step RAN with a cap looser than asked"
  fk tight '[ $# -eq 1 ] && echo 1000; [ $# -eq 2 ] && return 1; return 0'
  check "fcap: a cap that cannot be raised but already reads TIGHTER than asked (a tighter hard limit) is fine (the step runs)" 0 "$rc"; [ -e "$W/fran" ] || bad "fcap: the step did not run under a tighter inherited cap"
}

# ── disk-watch cases (ga-2d14tow): wcases <guard> <lib> ───────────────────────────────────────────────────
# The file cap above is per FILE: a mutant that writes MANY small files, or appends to one file after another, goes under it and empties the disk the same way
# (27/10: 4.2 and 5.6 GB, Dolt ENOSPC). So a selftest/mutant step also runs under the push class's watch: df is read every HEAVY_GUARD_WATCH_SECS and the step is
# stopped (TERM to its process group, KILL after the grace, rc 78) when the free disk falls under the stop floor, or by more than the drop limit since it started.
# The fake df reports WBASE MB minus what the writer REALLY wrote into $WF, so "the fixture's disk does not pass N MB" is measured. The writer ends by itself at 200
# files (~25 MB) only so that a guard WITHOUT the watch does not fill the disk of this selftest. WATCH_SECTIONS="drop floor" runs only those sections (default all).
wcases() {
  local g="$1" lib="$2" rc secs n n2 t0 out lbl gp WB="$W/wbin" WF="$W/wfix" wall=" ${WATCH_SECTIONS:-all} "
  wwant() { case "$wall" in *" all "*|*" $1 "*) return 0 ;; esac; return 1; }
  mkdir -p "$WB"
  cat > "$WB/df" <<EOF
#!/bin/sh
if [ -e "$W/wdfbad" ]; then echo "df: no usable answer"; exit 0; fi
kb=\$(du -sk "$WF" 2>/dev/null | cut -f1)
echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
echo "/dev/fake 100000 90000 \$(( \$(cat "$W/wbase") - \${kb:-0} / 1024 - \$(cat "$W/wjump" 2>/dev/null || echo 0) )) 90% /"
EOF
  chmod +x "$WB/df"
  # 128 KB a file, ~100 files a second: far under any per-file cap. WLOOP_BAD=<file> makes the fake df unreadable while it writes.
  cat > "$W/wloop.sh" <<'EOF'
#!/bin/bash
d="$1"; mkdir -p "$d"; [ -z "${WLOOP_BAD:-}" ] || : > "$WLOOP_BAD"
i=0; while [ "$i" -lt 200 ]; do i=$((i+1)); printf '%0131072d' 0 > "$d/f$i"; sleep 0.01; done
echo done > "$2"
EOF
  cp "$W/wloop.sh" "$W/wloop.selftest.sh"
  # a step whose writes make the disk "fall" 3000 MB at once (the fake df subtracts $W/wjump): only the 2048 MB DEFAULT limit can see it
  cat > "$W/wjump.sh" <<'EOF'
#!/bin/bash
d="$1"; mkdir -p "$d"; i=0
while [ "$i" -lt 150 ]; do i=$((i+1)); printf '%01024d' 0 > "$d/f$i"; [ "$i" = 5 ] && echo 3000 > "$WJUMP"; sleep 0.02; done
echo done > "$2"
EOF
  wrun() { # the guard on the fake df, a fresh fixture each time; leaves rc, secs and the number of files written
    rm -rf "$WF" "$W/wdone" "$W/wdfbad" "$W/wjump"; echo "${WBASE:-9000}" > "$W/wbase"; : > "$HEAVY_GUARD_LOG"; t0=$SECONDS
    WJUMP="$W/wjump" PATH="$WB:$PATH" DISK_HEADROOM_PATH=/ HEAVY_GUARD_LIB="$lib" HEAVY_GUARD_WATCH_SECS=1 HEAVY_GUARD_KILL_GRACE_SECS=2 "$g" "$@" >/dev/null 2>"$W/werr"; rc=$?
    secs=$((SECONDS - t0)); n="$(ls "$WF" 2>/dev/null | wc -l | tr -d ' ')"
  }
  wstopped() { # the last wrun ended by the watch: 78, long before the writer's 200 files, in seconds, nothing left running, the reason said and logged
    check "watch: $1: the guard ends with 78" 78 "$rc"
    [ ! -e "$W/wdone" ] || bad "watch: $1: the writer ran to the end, the watch did not stop it"
    [ "$n" -lt 150 ] || bad "watch: $1: $n of 200 files were written, the watch must stop the writer long before"
    [ "$secs" -lt 8 ] || bad "watch: $1: it took $secs s to stop a writer of ~12 MB/s"
    grep -q 'INTERRUPTED' "$W/werr" && grep -q 'rc 78' "$W/werr" || bad "watch: $1: stderr must say INTERRUPTED and rc 78 ($(cat "$W/werr"))"
    grep -q "INTERRUPTED what=.* class=step .*rc=78" "$HEAVY_GUARD_LOG" || bad "watch: $1: the log must have the INTERRUPTED line with class=step ($(cat "$HEAVY_GUARD_LOG"))"
    n2="$(ls "$WF" 2>/dev/null | wc -l | tr -d ' ')"; sleep 1.5
    [ "$(ls "$WF" 2>/dev/null | wc -l | tr -d ' ')" = "$n2" ] || bad "watch: $1: the writer kept writing after the guard returned, its process group was not stopped"
  }
  wuntouched() { # the last wrun ran to the end and the step's own rc came back
    check "watch: $1: the step's own rc comes back" 0 "$rc"
    [ -e "$W/wdone" ] || bad "watch: $1: the step was stopped at $n of 200 files (rc $rc), it must not be ($(head -c 300 "$W/werr"))"
  }
  if wwant core; then
    # the writer is double-forked from the step's leader (the leader sleeps): it stays in the step's process group but is no longer in its parent chain, so only the TERM to the GROUP reaches it
    wrun --what selftest-mutants --max-disk-drop-mb 4 -- bash -c '( bash "$0" "$@" & ); sleep 30' "$W/wloop.sh" "$WF" "$W/wdone"
    wstopped "a selftest label with --max-disk-drop-mb 4, the writer double-forked from the step (in its group, out of its parent chain)"
    grep -q 'fell' "$W/werr" && grep -q 'limit 4 MB' "$W/werr" || bad "watch: the drop refusal must say how far it fell and the limit ($(cat "$W/werr"))"
  fi
  if wwant escape; then
    # a battery runs each mutant under `timeout` (or with `set -m`, or setsid), which gives it a process group of its own: the group of the step does not hold it, and the runaway
    # went on writing. The step here is that battery: the writer runs in a group of its own; the watch has to find it by the parent chain and stop it with the rest.
    wrun --what selftest-mutants --max-disk-drop-mb 4 -- bash -c 'set -m; bash "$0" "$@" & wait $!; exit $?' "$W/wloop.sh" "$WF" "$W/wdone"
    wstopped "a writer that left the step's process group (set -m, like a mutant run under timeout)"
  fi
  if wwant class; then
    HEAVY_GUARD_SELFTEST_MAX_DROP_MB=4 wrun --what t -- bash "$W/wloop.selftest.sh" "$WF" "$W/wdone"
    wstopped "a *.selftest.sh word in the command, the limit from the env"
    HEAVY_GUARD_SELFTEST_MAX_DROP_MB=4 wrun --what other -- bash "$W/wloop.sh" "$WF" "$W/wdone"
    wuntouched "a step outside the class is not watched by the class default"
  fi
  if wwant caller; then
    HEAVY_GUARD_SELFTEST_MAX_DROP_MB=2048 wrun --what selftest --max-disk-drop-mb 4 -- bash "$W/wloop.sh" "$WF" "$W/wdone"
    wstopped "the caller's number beats the class default"
    HEAVY_GUARD_SELFTEST_MAX_DROP_MB=4 wrun --what selftest --max-disk-drop-mb 0 -- bash "$W/wloop.sh" "$WF" "$W/wdone"
    wuntouched "--max-disk-drop-mb 0 is the explicit way to lift the drop limit"
  fi
  if wwant optin; then
    wrun --what other --max-disk-drop-mb 4 -- bash "$W/wloop.sh" "$WF" "$W/wdone"
    wstopped "--max-disk-drop-mb 4 on a step that is not in the class"
  fi
  if wwant goclass; then
    HEAVY_GUARD_SELFTEST_MAX_DROP_MB=4 WBASE=20000 wrun --what go-test -- bash "$W/wloop.selftest.sh" "$WF" "$W/wdone"
    wuntouched "a Go step is not in the class even with a selftest word in its command"
  fi
  if wwant jdef; then
    wrun --what selftest -- bash "$W/wjump.sh" "$WF" "$W/wdone"
    wstopped "a fall of 3000 MB stops a selftest step with the DEFAULT limit"
  fi
  if wwant jenv; then
    for out in 0 abc 99999999999999999999; do
      HEAVY_GUARD_SELFTEST_MAX_DROP_MB="$out" wrun --what selftest -- bash "$W/wjump.sh" "$WF" "$W/wdone"
      wstopped "a class limit of '$out' in the env falls back to 2048 MB, it does not lift the limit"
    done
    HEAVY_GUARD_SELFTEST_MAX_DROP_MB=4000 wrun --what selftest -- bash "$W/wjump.sh" "$WF" "$W/wdone"
    wuntouched "a class limit of 4000 MB in the env lets a fall of 3000 MB through"
  fi
  if wwant jflag; then
    wrun --what selftest --max-disk-drop-mb 0 -- bash "$W/wjump.sh" "$WF" "$W/wdone"
    wuntouched "--max-disk-drop-mb 0 lets a fall of 3000 MB through (6000 MB are left, the floor is 4000)"
  fi
  if wwant bypass; then
    DISK_HEADROOM_ENABLED=0 wrun --what selftest -- bash "$W/wjump.sh" "$WF" "$W/wdone"
    wuntouched "with the kill switch on (checks off) the watch judges nothing"
  fi
  if wwant floor; then
    WBASE=4003 wrun --min-free-mb 4003 --what selftest --max-disk-drop-mb 0 -- bash "$W/wloop.sh" "$WF" "$W/wdone"
    wstopped "the stop floor alone (4003 MB at the start, 4000 MB floor)"
    grep -q 'stop floor' "$W/werr" && grep -q '4000 MB' "$W/werr" || bad "watch: the floor refusal must name the stop floor ($(cat "$W/werr"))"
    WBASE=3500 wrun --min-free-mb 3000 --what selftest --max-disk-drop-mb 0 -- bash "$W/wloop.sh" "$WF" "$W/wdone"
    wuntouched "a step the caller let start at 3000 MB is not stopped by the 4000 MB floor, which is clamped to its start floor"
  fi
  if wwant blind; then
    HEAVY_GUARD_SELFTEST_MAX_DROP_MB=4 WLOOP_BAD="$W/wdfbad" wrun --what selftest -- bash "$W/wloop.sh" "$WF" "$W/wdone"
    wuntouched "a df the watch cannot read does not kill the step"
    grep -q "WATCH_UNREADABLE what=" "$HEAVY_GUARD_LOG" || bad "watch: an unreadable round must leave the WATCH_UNREADABLE line ($(cat "$HEAVY_GUARD_LOG"))"
  fi
  if wwant plain; then
    wrun --what selftest --max-disk-drop-mb 4 -- bash -c 'exit 7'
    check "watch: a step that fails by itself keeps its own rc under the watch" 7 "$rc"
    out="$(DISK_FREE_OVERRIDE_MB=20000 HEAVY_GUARD_LIB="$lib" "$g" --what selftest -- sh -c 'echo hi; exit 3' 2>/dev/null)"; rc=$?
    check "watch: a selftest step on a pinned reading returns its rc" 3 "$rc"; [ "$out" = hi ] || bad "watch: the step's stdout must come through the watch (got '$out')"
    DISK_FREE_OVERRIDE_MB=20000 HEAVY_GUARD_LIB="$lib" "$g" --check --max-disk-drop-mb 4 --what selftest 2>/dev/null; rc=$?
    check "watch: --check accepts --max-disk-drop-mb (nothing runs, nothing to watch)" 0 "$rc"
    for out in abc -1 1234567890 ''; do
      DISK_FREE_OVERRIDE_MB=20000 HEAVY_GUARD_LIB="$lib" "$g" --max-disk-drop-mb "$out" --what t -- true 2>/dev/null; rc=$?
      check "watch: --max-disk-drop-mb '$out' is a usage error" 64 "$rc"
    done
    DISK_FREE_OVERRIDE_MB=20000 HEAVY_GUARD_LIB="$lib" "$g" --what t --max-disk-drop-mb 2>/dev/null; rc=$?
    check "watch: --max-disk-drop-mb without a value is a usage error" 64 "$rc"
  fi
  if wwant orphan; then
    # a guard that is KILLed (no trap runs) leaves the step and the watch behind; the watch runs in its own process group, so nothing else ends it: it must end by
    # itself once the step is gone, not read the disk for ever (and, with the pid recycled, one day TERM somebody else's group). The label is unique to this run.
    lbl="selftest-orphan-$$"; rm -rf "$WF" "$W/wdone" "$W/wdfbad" "$W/wjump"; echo 9000 > "$W/wbase"
    PATH="$WB:$PATH" DISK_HEADROOM_PATH=/ HEAVY_GUARD_LIB="$lib" HEAVY_GUARD_WATCH_SECS=1 "$g" --what "$lbl" --max-disk-drop-mb 4 -- sleep 3 > /dev/null 2>&1 &
    gp=$!; sleep 1.5; kill -KILL "$gp" 2> /dev/null; wait "$gp" 2> /dev/null; sleep 5.5   # the step ends at ~3 s, the watch notices at its next round
    out="$(pgrep -f "$lbl" | tr '\n' ' ')"
    if [ -z "$out" ]; then ok; else bad "watch: the watch of a KILLed guard outlived its step (pids: $out)"; for n in $out; do kill "$n" 2> /dev/null; done; fi
  fi
  if wwant sigterm; then
    # the guard itself told to stop (a `timeout` around a battery, the session closing). The step is not the guard any more (no exec), so without the guard's traps the TERM
    # would end the guard alone and leave the step and the watch running. The label is unique to this run and is on the command line of the step and of the watch (a
    # forked subshell keeps the guard's), which is how they are found; the step is a bash that waits, so that its sleep is no more than its child.
    lbl="selftest-sigterm-$$"; rm -rf "$WF" "$W/wdone" "$W/wdfbad" "$W/wjump"; echo 9000 > "$W/wbase"
    PATH="$WB:$PATH" DISK_HEADROOM_PATH=/ HEAVY_GUARD_LIB="$lib" HEAVY_GUARD_WATCH_SECS=1 HEAVY_GUARD_KILL_GRACE_SECS=2 "$g" --what "$lbl" -- bash -c 'sleep 30 & wait' "$lbl" > /dev/null 2>&1 &
    gp=$!; sleep 1.5; kill -TERM "$gp" 2> /dev/null; wait "$gp" 2> /dev/null; rc=$?
    check "watch: a guard that is told to stop exits 143" 143 "$rc"
    sleep 0.5; out="$(pgrep -f "$lbl" | tr '\n' ' ')"
    if [ -z "$out" ]; then ok; else bad "watch: the step or the watch outlived the guard that was told to stop (pids: $out)"; for n in $out; do kill "$n" 2> /dev/null; done; fi
  fi
}

mk_mutant() { # mk_mutant <src> <dst> <sed-expr>  — fails the selftest if the expression changed nothing
  # sed > file leaves mode 644, and the guard mutants are EXECUTED: without +x every one of them died with rc 126 (permission
  # denied) whatever it changed, so no mutant proved anything
  sed "$3" "$1" > "$2"; chmod +x "$2"; cmp -s "$1" "$2" && { bad "mutant '$3' did not change $(basename "$1")"; return 1; }; return 0
}

if [ "${HEAVY_GUARD_ST_ONLY:-}" = watch ]; then   # development shortcut: just the disk-watch cases, no mutants
  wcases "$REAL_GUARD" "$REAL_LIB"; echo "heavy-guard selftest (watch cases only): $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi
before=$FAIL; lib_cases "$REAL_LIB";                      [ "$FAIL" -eq "$before" ] || echo "(lib cases failed on the real lib)"
before=$FAIL; guard_cases "$REAL_GUARD" "$REAL_LIB";      [ "$FAIL" -eq "$before" ] || echo "(guard cases failed on the real files)"
before=$FAIL; go_cases "$REAL_GUARD" "$REAL_LIB";         [ "$FAIL" -eq "$before" ] || echo "(go cases failed on the real files)"
before=$FAIL; push_cases "$REAL_GUARD" "$REAL_LIB";       [ "$FAIL" -eq "$before" ] || echo "(push cases failed on the real files)"
before=$FAIL; lookup_cases "$REAL_GUARD";                 [ "$FAIL" -eq "$before" ] || echo "(lookup cases failed on the real guard)"
before=$FAIL; fcap_cases "$REAL_GUARD" "$REAL_LIB";       [ "$FAIL" -eq "$before" ] || echo "(file-cap cases failed on the real files)"
before=$FAIL; wcases "$REAL_GUARD" "$REAL_LIB";           [ "$FAIL" -eq "$before" ] || echo "(disk-watch cases failed on the real files)"

# mutants: each must make at least one case fail
survive() { # survive <name> -- the FAIL counter must have grown since $before
  if [ "$FAIL" -gt "$before" ]; then FAIL=$before; PASS=$((PASS+1)); else bad "mutant '$1' survived: no case noticed it"; fi
}
# the file-cap mutants under an ambient limit that is itself the cap (AMB_OK=0): the cases that would catch a dropped default cap were skipped, so a mutant nobody noticed is UNVERIFIED, not a survivor. One that a case
# DID notice is killed as always. With AMB_OK=1 it is exactly survive.
UNVER=0; UNVER_NAMES=""
survive_amb() { # survive_amb <name> -- the FAIL counter must have grown since $before, or (AMB_OK=0) the mutant is counted as unverified
  if [ "$FAIL" -gt "$before" ]; then FAIL=$before; PASS=$((PASS+1))
  elif [ "$AMB_OK" != 1 ]; then UNVER=$((UNVER+1)); UNVER_NAMES="$UNVER_NAMES [$1]"
  else bad "mutant '$1' survived: no case noticed it"; fi
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

# Go class mutants (ga-edkfip): each one removes or bends one rule of the class
mk_mutant "$REAL_LIB" "$M/lib-gocap.sh" '/^\[ "\${#DISK_GO_MIN_MB}" -le 9 \]/d' && { before=$FAIL; lib_cases "$M/lib-gocap.sh" >/dev/null; survive "lib: no magnitude cap on the Go floor"; }
mk_mutant "$REAL_LIB" "$M/lib-gogarb.sh" '/^case "\$DISK_GO_MIN_MB" in/d' && { before=$FAIL; lib_cases "$M/lib-gogarb.sh" >/dev/null; survive "lib: a Go floor that is not a number is kept"; }
mk_mutant "$REAL_LIB" "$M/lib-godef.sh" 's/DISK_GO_MIN_MB:-13312/DISK_GO_MIN_MB:-6144/' && { before=$FAIL; lib_cases "$M/lib-godef.sh" >/dev/null; survive "lib: the default Go floor is the heavy one"; }
gom() { # gom <file> <name> <sed-expr>
  mk_mutant "$REAL_GUARD" "$M/$1.sh" "$3" && { before=$FAIL; go_cases "$M/$1.sh" "$REAL_LIB" >/dev/null 2>&1; survive "$2"; }
}
gom g-go-nolabel  "guard: a Go label is not recognised"                       's#\^\[Gg\]\[Oo\]\[- _\]#NOPE_NOPE#'
gom g-go-case     "guard: the label verb is matched case-sensitively"          's#\[Tt\]\[Ee\]\[Ss\]\[Tt\]#test#'
gom g-go-trfallb  "guard: the old tr split with its silent || fallback is back" 's#^  norm="\${norm//\[\$seps\]/ }"$#  norm="$(printf %s "$norm" | tr ";\&|()" " ")" || norm=" $* "#'
gom g-go-nocmd    "guard: a Go command is not recognised"                     's#\[\[ \$norm =~ \$cre \]\] && return 0#:#'
gom g-go-notr     "guard: the argument list is not split on ; & | ( ) quotes" '\#^  norm="\${norm//\[#d'
gom g-go-noslash  "guard: a path before go is not a word boundary"            's#\[\[:space:\]/\]go#[[:space:]]go#'
gom g-go-wordend  "guard: go-testdata counts as go-test"                      's#)(\[^\[:alnum:\]\]|\$)#)#'
gom g-go-verbs    "guard: go version counts as a Go step"                     's#\[\[:space:\]\]+(test|build|vet|install)\[\[:space:\]\]#[[:space:]]+[a-z]+[[:space:]]#'
gom g-go-nofloor  "guard: a Go step keeps the heavy floor"                    's#^  \[ "\$min" -ge "\$DISK_GO_MIN_MB" \] 2>/dev/null || min="\$DISK_GO_MIN_MB"$#  :#'
gom g-go-lowers   "guard: --min-free-mb lowers the Go floor"                  's#\[ "\$min" -ge "\$DISK_GO_MIN_MB" \] 2>/dev/null || min="\$DISK_GO_MIN_MB"#[ "$min" -ne "$DISK_HEAVY_MIN_MB" ] 2>/dev/null || min="$DISK_GO_MIN_MB"#'
gom g-go-nomsg    "guard: the Go refusal does not point at the MacBook"       's#scripts/mbp-run.sh --exec --go --push#scripts/other --push#'
gom g-go-no98     "guard: the Go refusal does not warn that 97/98 are not 'MacBook down'" 's#98 also a --push path that does not exist#98 is down#'
gom g-go-nolog    "guard: the Go refusal log has no class=go"                 's# class=go rc=75# rc=75#'
gom g-go-no76     "guard: a lib without the Go floor is not refused"          's#^  if \[ -z "\${DISK_GO_MIN_MB:-}" \]; then$#  if false; then#'
gom g-go-wrongrc  "guard: the Go refusal uses the run-local rc 97"            's#^      exit 75$#      exit 97#'

# push class mutants (ga-pwd2h6): each one removes or bends one rule of the class; the sections named are the cases that can notice it
pgm() { # pgm <file> <name> <sections> <sed-expr>  (a mutant of the GUARD)
  mk_mutant "$REAL_GUARD" "$M/$1.sh" "$4" && { before=$FAIL; PUSH_SECTIONS="$3" push_cases "$M/$1.sh" "$REAL_LIB" >/dev/null 2>&1; survive "$2"; }
}
plm() { # plm <file> <name> <sed-expr>  (a mutant of the LIB)
  mk_mutant "$REAL_LIB" "$M/$1.sh" "$3" && { before=$FAIL; lib_cases "$M/$1.sh" >/dev/null 2>&1; survive "$2"; }
}
plm lib-pclamp   "lib: a push stop floor above the start floor is kept"       's#^\[ "\$DISK_PUSH_STOP_MB" -le "\$DISK_PUSH_MIN_MB" \] || DISK_PUSH_STOP_MB="\$DISK_PUSH_MIN_MB"$#:#'
plm lib-pgarb    "lib: a push start floor that is not a number is kept"        '/^case "\$DISK_PUSH_MIN_MB" in/d'
plm lib-pgarbs   "lib: a push stop floor that is not a number is kept"         '/^case "\$DISK_PUSH_STOP_MB" in/d'
plm lib-pcap     "lib: no magnitude cap on the push floors"                    '/^\[ "\${#DISK_PUSH_[A-Z_]*}" -le 9 \]/d'
plm lib-pdef     "lib: the default push start floor is the heavy one"          's/DISK_PUSH_MIN_MB:-5000/DISK_PUSH_MIN_MB:-6144/'
plm lib-pstopdef "lib: the default push stop floor is wrong"                   's/DISK_PUSH_STOP_MB:-4000/DISK_PUSH_STOP_MB:-3000/'
pgm p-nolabel    "push: a push label is not recognised"                         detect      's#^    \[\[ \$label =~ \$lre \]\] && return 0#    :#'
pgm p-labelwins  "push: a push label makes a non-push command a push"           detect      's|^  if \[ \$# -eq 0 \]; then$|  if [ $# -eq 0 ] \|\| [[ $label =~ ^[Pp]ush ]]; then|'
pgm p-anyprog    "push: any program followed by push counts"                    detect      's#^  case "\$1" in git|\*/git) ;; \*) return 1 ;; esac$#  :#'
pgm p-shift1     "push: a git option that takes a value eats only itself"       detect      's#--namespace) shift 2 || return 1 ;;#--namespace) shift ;;#'
pgm p-skipword   "push: an unknown word before push is skipped"                 detect      's#^      \*) return 1 ;;$#      *) shift ;;#'
pgm p-goover     "push: a Go step can also be a push (lower floor)"             detect      's#if \[ "\$go_class" = 0 \] && hg_push_step#if hg_push_step#'
pgm p-defheavy   "push: the default push floor is the heavy one"                floor       's#^      min="\$DISK_PUSH_MIN_MB"$#      :#'
pgm p-noverify   "push: the refusal does not say not to use --no-verify"        floor       's# and do NOT use --no-verify to get around the hook##'
pgm p-nolower    "push: --min-free-mb can lower the push floor"                 minfree     's#\[ "\$min" -ge "\$DISK_PUSH_MIN_MB" \] 2>/dev/null || min="\$DISK_PUSH_MIN_MB"#:#'
pgm p-nolibchk   "push: a lib without the push floors is not detected"          nopushlib   's#if \[ -n "\${DISK_PUSH_MIN_MB:-}" \] && \[ -n "\${DISK_PUSH_STOP_MB:-}" \]; then#if true; then#'
pgm p-nowatch    "push: a push runs without the watch and the lock"             stop        's#\[ "\$push_class" = 1 \] \&\& { HG_WKIND=push; hg_run_watched "\$@"; }#:#'
pgm p-stopmin    "push: the watch stops at the start floor, not the stop floor" stopfloor   's#stop="\$DISK_PUSH_STOP_MB" d$#stop="$DISK_PUSH_MIN_MB" d#'
pgm p-nostatus   "push: the watch that stopped the push exits 0, the guard never hears it" stop   's#^        exit 78 ;;$#        exit 0 ;;#'
pgm p-lateignore "push: the watch ignores the guard's TERM only after it stopped the push"  stop   "/^        trap '' TERM\$/d; s#^        hg_stop_group \"\\\$pid\"\$#        hg_stop_group \"\$pid\"; trap '' TERM#"
pgm p-nowaitw    "push: the guard does not read the watch's status"             stop        's#^  { wait "\$HG_WATCHER"; } 2>/dev/null; wrc=\$?$#  wrc=0#'
pgm p-usr1back   "push: the guard traps USR1 again (a signal that cuts its wait)"   race        "s#^  trap 'hg_on_signal' TERM INT HUP\$#  trap 'hg_on_signal' TERM INT HUP; trap : USR1#"
pgm p-leaderonly "push: the TERM goes to the push only, not its group"          stop        's#kill -TERM -- "-\$p" 2>/dev/null || kill -TERM "\$p" 2>/dev/null || return 0#kill -TERM "$p" 2>/dev/null || return 0#'
pgm p-nokill     "push: a push that ignores TERM is never KILLed"               ignoreterm  's#^    kill -KILL .*$#    :#'
pgm p-rc0        "push: a push that ended with 0 is turned into a 78"           term0       's#^  if \[ "\$wrc" = 78 \] && \[ "\$rc" -ne 0 \]; then rc=78; fi$#  if [ "$wrc" = 78 ]; then rc=78; fi#'
pgm p-anywrc     "push: any watch status but 0 turns the push's rc into a 78"   rc          's#^  if \[ "\$wrc" = 78 \] && \[ "\$rc" -ne 0 \]; then rc=78; fi$#  if [ "$wrc" != 0 ] \&\& [ "$rc" -ne 0 ]; then rc=78; fi#'
pgm p-blindkills "push: a reading the watch cannot take kills the push"         blind       's#^      low|drop)$#      low|drop|*)#'
pgm p-nolock     "push: no lock is taken"                                       serial      's#then hg_push_lock_acquire; fi#then :; fi#'
pgm p-norelease  "push: the lock is never let go"                               serial      's#^  rmdir "\$HG_LOCK_DIR" 2>/dev/null$#  :#'
pgm p-noexittrap "push: a refused push leaves the lock behind"                  diskrelease "s#^  trap 'hg_lock_release' EXIT\$#  :#"
pgm p-zerowait   "push: a wait of 0 is not allowed"                             posint        's#\[ "\$4" = 1 \] ||#false ||#'
pgm p-octal      "push: a zero-padded number is read as octal"                  posint        's@^  v=\$(( 10#\$v ))$@  v=$(( v ))@'
pgm p-maxage     "push: a lock older than the max age is never stale"           age         's@\*) \[ \$(( now - 10#\$at )) -le "\$HG_LOCK_MAXAGE" \] || { HG_LOCK_VERDICT=stale; return 0; } ;;@*) : ;;@'
pgm p-deadholder "push: a lock whose holder is dead is never stale"             dead        's#^    kill -0 "\$pid" 2>/dev/null || HG_LOCK_VERDICT=stale$#    :#'
pgm p-garbage    "push: a lock that cannot be judged is taken"                  garbage     '/case "\$pid" in/s#return 0 ;; esac#{ HG_LOCK_VERDICT=stale; return 0; } ;; esac#'
pgm p-freshdir   "push: a fresh ownerless lock directory is taken"              fresh       's#^  \[ "\$old" != "\$HG_LOCK_DIR" \] || HG_LOCK_VERDICT=stale$#  HG_LOCK_VERDICT=stale#'
pgm p-nocreate   "push: a lock that cannot be created is waited on"             nocreate    's#^    if \[ ! -d "\$HG_LOCK_DIR" \]; then$#    if false; then#'
pgm p-nosigtrap  "push: the guard does not forward a TERM to the push"          sigterm     "s#^  trap 'hg_on_signal' TERM INT HUP\$#  :#"

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

fcm() { # fcm <file> <name> <sed-expr>  (a mutant of the GUARD, run through the file-cap cases)
  mk_mutant "$REAL_GUARD" "$M/$1.sh" "$3" && { before=$FAIL; fcap_cases "$M/$1.sh" "$REAL_LIB" >/dev/null 2>&1; survive_amb "$2"; }
}
# file cap (ga-e6ug8gq): every line of the class has a mutant that the cases above must notice
fcm f-nocap    "fcap: the cap is never applied"                                 's#^    if \[ "\$fcap_mb" -gt 0 \] && ! hg_apply_fcap "\$fcap_mb"; then$#    if false; then#'
fcm f-unit     "fcap: the MB are not turned into 1024-byte blocks"              's#local kb=\$(( \$1 \* 1024 )) cur#local kb=$(( $1 )) cur#'
fcm f-defsize  "fcap: the default class cap is not 512 MB"                      's#"\${HEAVY_GUARD_SELFTEST_MAX_FILE_MB:-}" 512 0#"${HEAVY_GUARD_SELFTEST_MAX_FILE_MB:-}" 1024 0#'
fcm f-defenv   "fcap: the class cap seam in the env is ignored"                 's#"\${HEAVY_GUARD_SELFTEST_MAX_FILE_MB:-}" 512 0#"" 512 0#'
fcm f-defzero  "fcap: a class cap of 0 in the env uncaps the selftests"         's#"\${HEAVY_GUARD_SELFTEST_MAX_FILE_MB:-}" 512 0#"${HEAVY_GUARD_SELFTEST_MAX_FILE_MB:-}" 512 1#'
fcm f-nomatch  "fcap: no step is recognised as a selftest or a mutant battery"  's#^  \[\[ " \$label \$\* " =~ \$cre \]\] && return 0$#  :#'
fcm f-nolabel  "fcap: the label is not read for the class"                      's#\[\[ " \$label \$\* " =~ \$cre \]\]#[[ " $* " =~ $cre ]]#'
fcm f-nocmd    "fcap: the command words are not read for the class"             's#\[\[ " \$label \$\* " =~ \$cre \]\]#[[ " $label " =~ $cre ]]#'
fcm f-case     "fcap: the class words are matched case-sensitively"             's#\[Mm\]\[Uu\]\[Tt\]#mut#'
fcm f-nomutat  "fcap: mutate / mutation do not count as mutant batteries"        's#(\[Aa\]\[Nn\]\[Tt\]|\[Aa\]\[Tt\])#([Aa][Nn][Tt])#'
fcm f-nogit    "fcap: a git command (repack, push) is in the class"             's#^  case "\${1:-}" in git|\*/git) return 1 ;; esac$#  :#'
fcm f-gocap    "fcap: a Go step is capped by the class"                         's#^elif \[ "\$go_class" = 0 \] && hg_selftest_step#elif hg_selftest_step#'
fcm f-giveup   "fcap: the caller's number does not beat the class default"      '/^fcap_mb=0$/{n;s#^if \[ "\$fcap_given" = 1 \]; then$#if false; then#;}'
fcm f-zero     "fcap: --max-file-mb 0 sets a cap of zero instead of none"        's#\[ "\$fcap_mb" -gt 0 \]#[ "$fcap_mb" -ge 0 ]#'
fcm f-set      "fcap: a cap that cannot be raised is refused even when tighter" 's#^  ulimit -f "\$kb" 2>/dev/null$#  ulimit -f "$kb" 2>/dev/null || return 1#'
fcm f-noread   "fcap: the cap is not read back"                                 's#^  cur="\$(ulimit -f 2>/dev/null)" || return 1$#  return 0#'
fcm f-loose    "fcap: a looser cap than asked is taken for the one asked"        's#^  \[ "\$cur" -le "\$kb" \] 2>/dev/null$#  true#'
fcm f-unlim    "fcap: a reading that cannot be compared is taken as capped"      's#^  \[ "\$cur" -le "\$kb" \] 2>/dev/null$#  [ "$cur" -gt "$kb" ] 2>/dev/null \&\& return 1; return 0#'
fcm f-open     "fcap: the refusal lets the step run (fail open)"                 '/fsize_cap_mb=\$fcap_mb unsettable/{n;s/exit 76/:/;}'
fcm f-nolog    "fcap: the refusal leaves no log line"                            '/hg_log "REFUSED what=.\$what. fsize_cap_mb/d'
fcm f-nomsg    "fcap: the refusal does not say it is rc 76"                      '/could not be set or read back/s#(rc 76)" >&2$#" >\&2#'
fcm f-nodigit  "fcap: --max-file-mb accepts anything"                           's#^  case "\$fcap" in .*exit 64 ;; esac$#  :#'
fcm f-nolen    "fcap: --max-file-mb has no magnitude cap"                        '/^  \[ "\${#fcap}" -le 9 \]/d'

# disk watch for the selftest/mutant class (ga-2d14tow): every rule of the class has a mutant that the cases of its section must notice
wcm() { # wcm <file> <name> <sections> <sed-expr>  (a mutant of the GUARD, run through the watch cases)
  mk_mutant "$REAL_GUARD" "$M/$1.sh" "$4" && { before=$FAIL; WATCH_SECTIONS="$3" wcases "$M/$1.sh" "$REAL_LIB" >/dev/null 2>&1; survive "$2"; }
}
wcm w-nodrop    "watch: the drop rule never fires"                                   core   's#^      \[ "\$d" -lt "\$HG_WDROP" \] || st=drop$#      :#'
wcm w-noclass   "watch: no selftest/mutant step is watched"                          class   's#^  if \[ "\$go_class" = 0 \] \&\& hg_selftest_step "\$what" "\$@"; then$#  if false; then#'
wcm w-allsteps  "watch: every step is watched with the class default"                class   's#^  if \[ "\$go_class" = 0 \] \&\& hg_selftest_step "\$what" "\$@"; then$#  if [ "$go_class" = 0 ]; then#'
wcm w-goclass   "watch: a Go step is in the class"                                   goclass   's#^  if \[ "\$go_class" = 0 \] \&\& hg_selftest_step "\$what" "\$@"; then$#  if hg_selftest_step "$what" "$@"; then#'
wcm w-noptin    "watch: --max-disk-drop-mb on a step outside the class is ignored"   optin   's#^  elif \[ "\$drop_mb" -gt 0 \]; then$#  elif false; then#'
wcm w-callerlose "watch: the class default beats the caller's number"                 caller   's#^    \[ "\$drop_given" = 1 \] || drop_mb="\$HG_DROP_DEFAULT"$#    drop_mb="$HG_DROP_DEFAULT"#'
wcm w-zerodrop  "watch: a drop limit of 0 is a limit of 0 MB (stops at once)"         caller   's#\[ "\$HG_WDROP" -gt 0 \]#[ "$HG_WDROP" -ge 0 ]#'
wcm w-envzero   "watch: a class limit of 0 in the env lifts the drop rule"            jenv   's#"\${HEAVY_GUARD_SELFTEST_MAX_DROP_MB:-}" 2048 0#"${HEAVY_GUARD_SELFTEST_MAX_DROP_MB:-}" 2048 1#'
wcm w-defbig    "watch: the default drop limit is 8192 MB"                            jdef   's#"\${HEAVY_GUARD_SELFTEST_MAX_DROP_MB:-}" 2048 0#"${HEAVY_GUARD_SELFTEST_MAX_DROP_MB:-}" 8192 0#'
wcm w-envignored "watch: the class limit in the env is ignored"                       class   's#"\${HEAVY_GUARD_SELFTEST_MAX_DROP_MB:-}" 2048 0#"" 2048 0#'
wcm w-nofloor   "watch: the stop floor never fires for a step"                        floor  's#^  \[ "\$HG_WKIND" != step \] || stop="\$HG_WSTOP"$#  [ "$HG_WKIND" != step ] || stop=0#'
wcm w-noclamp   "watch: the stop floor is not pulled down to the start floor"         floor  's#^      \[ "\$HG_WSTOP" -le "\$min" \] 2>/dev/null || HG_WSTOP="\$min"$#      :#'
wcm w-blindkill "watch: a round the watch cannot read kills the step"                 blind  's#^      low|drop)$#      low|drop|*)#'
wcm w-notraps   "watch: the step has no traps, a TERM to the guard leaves the step and the watch running" sigterm  's#^      hg_traps$#      :#'
wcm w-nostatus  "watch: the watch that stopped the step exits 0, the guard never hears it"  core   's#^        exit 78 ;;$#        exit 0 ;;#'
wcm w-leader    "watch: the TERM goes to the step only, not its process group"        core   's#kill -TERM -- "-\$p" 2>/dev/null || kill -TERM "\$p" 2>/dev/null || return 0#kill -TERM "$p" 2>/dev/null || return 0#'
wcm w-startzero "watch: the drop is counted from 0, not from the reading at the start" core  's#HG_WSTART="\$free"; HG_WSTOP=#HG_WSTART=0; HG_WSTOP=#'
wcm w-bypass    "watch: the kill switch does not switch the drop rule off"            bypass   's# \&\& \[ "\${DISK_HEADROOM_ENABLED:-1}" != 0 \]; then$#; then#'
wcm w-nowatch   "watch: the step runs without the watch"                              core   's#^      hg_run_watched "\$@"$#      :#'
wcm w-nooption  "watch: --max-disk-drop-mb is not an option"                          plain  's#^    --max-disk-drop-mb) drop=#    --max-disk-drop-mbX) drop=#'
wcm w-nodigit   "watch: --max-disk-drop-mb accepts anything"                          plain  's#^  case "\$drop" in .*exit 64 ;; esac$#  :#'
wcm w-nolen     "watch: --max-disk-drop-mb has no magnitude cap"                      plain  '/^  \[ "\${#drop}" -le 9 \]/d'
wcm w-orphan    "watch: the watch outlives a step whose guard was KILLed"            orphan 's#^    kill -0 "\$pid" 2>/dev/null || return 0$#    :#'
wcm w-notree    "watch: a descendant outside the step's process group is left running" escape 's#^  tree="\$(hg_descendants "\$p" 2>/dev/null)" || tree=""$#  tree=""#'

[ "$AMB_OK" = 1 ] || echo "AMBIENTE: the inherited write limit ($(bash -c 'ulimit -S -f' 2>/dev/null) soft, $(bash -c 'ulimit -H -f' 2>/dev/null) hard, in KB) is already a cap of 512 MB or less: the cases that tell 'capped at 512 MB' from 'not capped' did not run and $UNVER file-cap mutant(s) are UNVERIFIED:${UNVER_NAMES:- none} (run this selftest without the cap: heavy-guard.sh --max-file-mb 0, or bare on the node)"
echo "heavy-guard selftest: $PASS passed, $FAIL failed$([ "$AMB_OK" = 1 ] || echo ", $UNVER mutant(s) UNVERIFIED (AMBIENTE)")"
[ "$FAIL" -eq 0 ] || exit 1
[ "$AMB_OK" = 1 ] || exit 97
exit 0
