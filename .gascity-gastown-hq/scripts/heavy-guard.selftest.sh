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
  DISK_FREE_OVERRIDE_MB=20000 run --check; rc=$?;           check "--check ok" 0 "$rc"
  DISK_FREE_OVERRIDE_MB=3000 run --check 2>/dev/null; rc=$?;  check "--check low" 75 "$rc"
  DISK_FREE_OVERRIDE_MB=x run --check 2>/dev/null; rc=$?;     check "--check unknown" 76 "$rc"
  DISK_FREE_OVERRIDE_MB=4000 run --min-free-mb 3000 --check; rc=$?;          check "custom floor below the reading" 0 "$rc"
  DISK_FREE_OVERRIDE_MB=6143 run --check 2>/dev/null; rc=$?;  check "one MB under the default heavy floor (6144)" 75 "$rc"
  DISK_FREE_OVERRIDE_MB=6144 run --check; rc=$?;              check "exactly the default heavy floor" 0 "$rc"
  # arguments reach the command intact, spaces included
  out="$(DISK_FREE_OVERRIDE_MB=20000 run -- sh -c 'printf "%s|" "$@"' _ "a b" "c")"
  [ "$out" = "a b|c|" ] || bad "guard: arguments must reach the command intact (got '$out')"
  # usage errors
  run 2>/dev/null; rc=$?;                                   check "no command and no --check" 64 "$rc"
  run --bogus 2>/dev/null; rc=$?;                           check "unknown option" 64 "$rc"
  run --min-free-mb abc --check 2>/dev/null; rc=$?;         check "non-numeric floor" 64 "$rc"
  run --wait-secs -1 --check 2>/dev/null; rc=$?;            check "non-numeric wait" 64 "$rc"
  # lib missing -> cannot decide -> refuse (76), never run
  rm -f "$W/ran"
  HEAVY_GUARD_LIB=/nonexistent-lib "$g" -- sh -c 'touch "$1"' _ "$W/ran" 2>/dev/null; rc=$?
  check "missing lib refuses" 76 "$rc"; [ ! -e "$W/ran" ] || bad "missing lib: the command RAN"
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
}

mk_mutant() { # mk_mutant <src> <dst> <sed-expr>  — fails the selftest if the expression changed nothing
  sed "$3" "$1" > "$2"; cmp -s "$1" "$2" && { bad "mutant '$3' did not change $(basename "$1")"; return 1; }; return 0
}

before=$FAIL; lib_cases "$REAL_LIB";                      [ "$FAIL" -eq "$before" ] || echo "(lib cases failed on the real lib)"
before=$FAIL; guard_cases "$REAL_GUARD" "$REAL_LIB";      [ "$FAIL" -eq "$before" ] || echo "(guard cases failed on the real files)"

# mutants: each must make at least one case fail
survive() { # survive <name> -- the FAIL counter must have grown since $before
  if [ "$FAIL" -gt "$before" ]; then FAIL=$before; PASS=$((PASS+1)); else bad "mutant '$1' survived: no case noticed it"; fi
}
M="$W/mut"; mkdir -p "$M"
mk_mutant "$REAL_LIB" "$M/lib-le.sh" 's/-lt "\$_dh_min"/-le "$_dh_min"/' && { before=$FAIL; lib_cases "$M/lib-le.sh" >/dev/null; survive "lib: -lt became -le"; }
mk_mutant "$REAL_LIB" "$M/lib-gt.sh" 's/-lt "\$_dh_min"/-gt "$_dh_min"/' && { before=$FAIL; lib_cases "$M/lib-gt.sh" >/dev/null; survive "lib: comparison inverted"; }
mk_mutant "$REAL_LIB" "$M/lib-unk.sh" "s/\*\[!0-9\]\*) return 1 ;; esac\$/*[!0-9]*) printf 0; return 0 ;; esac/" && { before=$FAIL; lib_cases "$M/lib-unk.sh" >/dev/null; survive "lib: unreadable collapses to 0 MB"; }
mk_mutant "$REAL_LIB" "$M/lib-ok.sh" "s/{ printf 'unknown'; return 0; }/{ printf 'ok'; return 0; }/" && { before=$FAIL; lib_cases "$M/lib-ok.sh" >/dev/null; survive "lib: unknown collapses to ok"; }
mk_mutant "$REAL_GUARD" "$M/g-run.sh" 's/exit 75/exec "$@"/' && { before=$FAIL; guard_cases "$M/g-run.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: low runs the command anyway"; }
mk_mutant "$REAL_GUARD" "$M/g-local.sh" 's/exit 75/exit 97/' && { before=$FAIL; guard_cases "$M/g-local.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: refusal uses the run-local rc 97"; }
mk_mutant "$REAL_GUARD" "$M/g-open.sh" 's/^    exit 76$/    exec "$@"/' && { before=$FAIL; guard_cases "$M/g-open.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: unknown disk runs the command (fail open)"; }
mk_mutant "$REAL_GUARD" "$M/g-nowait.sh" 's/\[ "\$now" -ge "\$deadline" \]/true/' && { before=$FAIL; guard_cases "$M/g-nowait.sh" "$REAL_LIB" >/dev/null 2>&1; survive "guard: never waits"; }

echo "heavy-guard selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
